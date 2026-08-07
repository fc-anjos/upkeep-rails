require "digest"

module Upkeep
  # The single doorway between upkeep and the SQL parser. Everything here is
  # cost-shaped by two rules:
  #
  #   Rule zero — off the hot path. Each distinct SQL *shape* is parsed once,
  #   cached by digest of its placeholder text (binds excluded — Rails hands
  #   us `?` placeholders in BoundSqlLiteral, so the shape is naturally
  #   bind-free). The cache is capped and evicting; a parse failure is a
  #   permanent "opaque" entry so a bad shape never costs a second parse.
  #
  #   Rule one — never a correctness authority. Every entry point returns nil
  #   for anything it cannot vouch for, and callers treat nil as "use today's
  #   conservative behavior". A wrong answer here may cost extra refreshes,
  #   never staleness.
  module SqlAnalysis
    MAX_ENTRIES = 512
    OPAQUE = :opaque

    class << self
      # Compile a where-clause fragment ("start_date <= ? AND ...") into a
      # structured predicate (see SqlPredicate). `binds` are the capture-time
      # positional bind values; `table` is the relation's own table (bare
      # columns attribute to it). Returns the fragment hash or nil (opaque).
      def fragment(sql, table:, binds: [], aliases: {}, covered: [])
        key = "fragment:#{table}:#{aliases.sort.inspect}:#{covered.sort.inspect}:#{sql}"
        compiled = cached(key) do
          SqlPredicate.compile(
            where_ast(sql, table), table: table, aliases: aliases, covered: covered
          )
        end
        return nil if compiled == OPAQUE
        SqlPredicate.with_binds(compiled, binds)
      end

      # The raw-SQL where node shapes Arel produces: BoundSqlLiteral (the
      # modern where("... ?", v) — placeholders and binds kept separate,
      # exactly what the shape cache wants), bare SqlLiteral, and a
      # Grouping around one. Returns [sql, binds] or nil.
      def arel_fragment(node)
        if defined?(Arel::Nodes::BoundSqlLiteral) && node.is_a?(Arel::Nodes::BoundSqlLiteral)
          return nil if node.named_binds.present?
          [node.sql_with_placeholders.to_s, node.positional_binds]
        elsif node.is_a?(Arel::Nodes::Grouping) && node.expr.is_a?(Arel::Nodes::SqlLiteral)
          [node.expr.to_s, []]
        elsif node.is_a?(Arel::Nodes::SqlLiteral)
          [node.to_s, []]
        end
      end

      # Column names assigned by a raw-string SET list
      # ("position = position + 1, updated_at = ..."). nil when unparseable.
      def set_columns(table, set_sql)
        columns = cached("set:#{table}:#{set_sql}") do
          update = parse("UPDATE #{quote(table)} SET #{set_sql}").fetch("Update")
          update.fetch("assignments").map(&:first)
        end
        columns == OPAQUE ? nil : columns
      end

      # Physical tables read by an arbitrary SQL statement (completeness-
      # audit attribution). nil when the statement cannot be parsed; [] when
      # it parses but reads no table (SELECT 1).
      def statement_tables(sql)
        tables = cached("tables:#{sql}") { scope_tables(parse(sql)) }
        tables == OPAQUE ? nil : tables
      end

      # Alias resolution for a string JOIN clause hanging off `table`:
      # {tables: [physical tables joined], aliases: {alias => physical|:scope}}.
      # nil when the join cannot be parsed.
      def join_analysis(table, join_sql)
        analysis = cached("join:#{table}:#{join_sql}") do
          scope = SQLGlot.build_scope(parse("SELECT * FROM #{quote(table)} #{join_sql}"))
          resolve_join_scope(scope, table)
        end
        analysis == OPAQUE ? nil : analysis
      end

      def dialect
        @dialect ||= dialect_from_adapter
      end

      attr_writer :dialect

      def reset!
        @mutex&.synchronize { @cache = {}; @order = [] }
        @dialect = nil
      end

      def cache_stats = @stats ||= Hash.new(0)

      private

      # Digest-keyed, capped, FIFO-evicting parse cache. A failure inside
      # the block is cached as OPAQUE — permanently "conservative", never
      # re-parsed. Misses never raise out to the caller.
      def cached(key)
        digest = Digest::SHA256.digest(key)
        mutex.synchronize do
          if @cache.key?(digest)
            cache_stats[:hits] += 1
            return @cache[digest]
          end
        end
        cache_stats[:misses] += 1
        value = begin
          yield
        rescue StandardError
          OPAQUE
        end
        store(digest, value)
      end

      def store(digest, value)
        mutex.synchronize do
          unless @cache.key?(digest)
            @cache[digest] = value
            @order << digest
            @cache.delete(@order.shift) while @order.size > MAX_ENTRIES
          end
          @cache[digest]
        end
      end

      def mutex
        @mutex ||= begin
          @cache = {}
          @order = []
          Mutex.new
        end
      end

      def parse(sql)
        SQLGlot.parse(sql, dialect: dialect)
      end

      def where_ast(fragment_sql, table)
        parse("SELECT * FROM #{quote(table)} WHERE #{fragment_sql}")
          .fetch("Select").fetch("where_clause")
      end

      def quote(table) = %("#{table}")

      def dialect_from_adapter
        adapter = ActiveRecord::Base.connection_db_config.adapter.to_s
        SQLGlot::Dialect.resolve(adapter.sub(/\Asqlite3\z/, "sqlite"))
      rescue StandardError
        "ansi"
      end

      # Every physical table any scope in the statement reads.
      def scope_tables(statement)
        SQLGlot.build_scope(statement).walk.flat_map do |scope|
          scope.sources.values.filter_map { |source| source.table&.name }
        end.uniq.sort
      end

      # {tables:, aliases:} for a JOIN scope: direct table sources map their
      # alias to the physical name; derived-table (subquery) sources map
      # their alias to :scope, and their inner tables join the table list.
      def resolve_join_scope(scope, own_table)
        tables = []
        aliases = {}
        scope.sources.each do |name, source|
          if source.table
            tables << source.table.name
            aliases[name] = source.table.name
          else
            aliases[name] = :scope
            tables.concat(scope_sources(source.scope))
          end
        end
        scope.child_scopes.each { |child| tables.concat(scope_sources(child)) }
        { tables: (tables - [own_table]).uniq.sort, aliases: aliases }
      end

      def scope_sources(scope)
        scope.walk.flat_map do |s|
          s.sources.values.filter_map { |source| source.table&.name }
        end
      end
    end
  end
end
