# frozen_string_literal: true

require "set"

module Upkeep
  # Lowers a SQLGlot statement into the small, generic dependency contract
  # needed by Upkeep. This layer knows SQL, not Active Record or Arel.
  module SQLDependencyAnalysis
    class UnsupportedError < StandardError; end

    Result = Data.define(
      :table_columns,
      :predicates,
      :equality_edges,
      :limit_value,
      :appendable,
      :warnings
    ) do
      def tables = table_columns.keys.sort
      def appendable? = appendable
    end

    Source = Data.define(:physical_tables)

    module_function

    # @param statement [Hash] AST returned by Sqlglot.parse
    # @param schema [Hash<String, Hash<String, String>>] SQLGlot-compatible
    #   table/column/type mapping.
    # @param scope [Sqlglot::Scope, nil] optional scope returned by
    #   Sqlglot.build_scope for semantic completeness validation.
    def analyze(statement, schema:, scope: nil)
      Analyzer.new(statement, schema: schema, scope: scope).analyze
    end

    # SQLGlot's established qualify_columns pass expands SELECT wildcards.
    # Upkeep uses qualification for source resolution, but collection
    # invalidation must not turn SELECT table.* into every table column: record
    # rendering tracks those attributes separately. Restore wildcard
    # projections while retaining qualification everywhere else.
    def preserve_wildcard_projections(original, qualified)
      ProjectionPreserver.new(original, qualified).call
    end

    class Analyzer
      def initialize(statement, schema:, scope:)
        @statement = statement
        @scope = scope
        @columns_by_table = normalize_schema(schema)
        @table_columns = Hash.new { |hash, table| hash[table] = Set.new }
        @predicates = []
        @equality_edges = Set.new
        @warnings = []
      end

      def analyze
        root = @statement["Select"]
        set_operation = @statement["SetOperation"]

        if root
          process_select(root, outer_sources: {}, visible_ctes: {})
        elsif set_operation
          process_set_operation(
            set_operation,
            outer_sources: {},
            visible_ctes: {}
          )
        else
          raise UnsupportedError, "expected a SELECT or set-operation statement"
        end

        validate_scope!

        Result.new(
          table_columns: normalized_table_columns,
          predicates: normalized_predicates,
          equality_edges: @equality_edges.to_a.sort,
          limit_value: literal_value((root || set_operation)["limit"]),
          appendable: root ? appendable?(root) : false,
          warnings: @warnings.uniq.sort
        )
      end

      private

      def validate_scope!
        return unless @scope

        ScopeValidator.new(
          @scope,
          columns_by_table: @columns_by_table,
          table_columns: @table_columns
        ).validate!
      end

      def process_select(select, outer_sources:, visible_ctes:)
        ctes = visible_ctes.dup

        Array(select["ctes"]).each do |cte|
          before = @table_columns.keys.to_set
          process_query(cte["query"], outer_sources: outer_sources, visible_ctes: ctes)
          physical_tables = @table_columns.keys.to_set - before
          physical_tables.merge(physical_tables_in(cte["query"], ctes))
          ctes[cte["name"]] = Source.new(physical_tables.to_a.sort)
        end

        local_sources = source_map(select, ctes, outer_sources)
        sources = outer_sources.merge(local_sources)
        walk_select_body(select, sources: sources, visible_ctes: ctes)
      end

      def process_query(query, outer_sources:, visible_ctes:)
        if query.is_a?(Hash) && query.key?("Select")
          process_select(
            query.fetch("Select"),
            outer_sources: outer_sources,
            visible_ctes: visible_ctes
          )
        elsif query.is_a?(Hash) && query.key?("SetOperation")
          process_set_operation(
            query.fetch("SetOperation"),
            outer_sources: outer_sources,
            visible_ctes: visible_ctes
          )
        else
          walk(query, sources: outer_sources, visible_ctes: visible_ctes)
        end
      end

      def process_set_operation(operation, outer_sources:, visible_ctes:)
        process_query(operation["left"], outer_sources: outer_sources, visible_ctes: visible_ctes)
        process_query(operation["right"], outer_sources: outer_sources, visible_ctes: visible_ctes)
      end

      def source_map(select, ctes, outer_sources)
        nodes = [select.dig("from", "source")]
        nodes.concat(Array(select["joins"]).map { |join| join["table"] })

        nodes.compact.each_with_object({}) do |node, sources|
          if node.is_a?(Hash) && node.key?("Table")
            table = node.fetch("Table")
            name = table["name"]
            physical_name = qualified_table_name(table)
            unless ctes[name] || @columns_by_table.key?(physical_name)
              raise UnsupportedError, "table #{physical_name} is not present in the schema"
            end

            source = ctes[name] || Source.new([physical_name])
            sources[name] = source
            sources[table["alias"]] = source if present?(table["alias"])
            source.physical_tables.each { |physical| @table_columns[physical] }
          elsif node.is_a?(Hash) && node.key?("Subquery")
            subquery = node.fetch("Subquery")
            before = @table_columns.keys.to_set
            process_query(
              subquery["query"],
              outer_sources: outer_sources.merge(sources),
              visible_ctes: ctes
            )
            physical = (@table_columns.keys.to_set - before).to_a
            physical = physical_tables_in(subquery["query"], ctes) if physical.empty?
            alias_name = subquery["alias"]
            sources[alias_name] = Source.new(physical.sort) if present?(alias_name)
          else
            raise UnsupportedError, "unsupported SQL source shape: #{node_shape(node)}"
          end
        end
      end

      def walk_select_body(select, sources:, visible_ctes:)
        select.each do |key, value|
          next if %w[ctes from where_clause having].include?(key)

          if key == "joins"
            Array(value).each do |join|
              walk(
                join.reject { |join_key, _value| join_key == "table" },
                sources: sources,
                visible_ctes: visible_ctes
              )
              record_predicates(join["on"], sources)
            end
          else
            walk(value, sources: sources, visible_ctes: visible_ctes)
          end
        end

        walk(select["where_clause"], sources: sources, visible_ctes: visible_ctes)
        walk(select["having"], sources: sources, visible_ctes: visible_ctes)
        record_predicates(select["where_clause"], sources)
        record_predicates(select["having"], sources)
      end

      def walk(node, sources:, visible_ctes:)
        case node
        when Array
          node.each { |child| walk(child, sources: sources, visible_ctes: visible_ctes) }
        when Hash
          if node.key?("Select")
            process_select(
              node.fetch("Select"),
              outer_sources: sources,
              visible_ctes: visible_ctes
            )
          elsif node.key?("SetOperation")
            process_set_operation(
              node.fetch("SetOperation"),
              outer_sources: sources,
              visible_ctes: visible_ctes
            )
          elsif node.key?("Column")
            record_resolved_column(node.fetch("Column"), sources)
          else
            node.each_value do |child|
              walk(child, sources: sources, visible_ctes: visible_ctes)
            end
          end
        end
      end

      def record_resolved_column(column, sources)
        name = column.fetch("name")
        candidates = resolved_tables(column, sources)

        if candidates.one?
          record_column(candidates.first, name)
        elsif candidates.empty?
          raise UnsupportedError,
            "column #{qualified_column_name(column)} has no physical source"
        else
          candidates.each { |table| record_column(table, name) }
          @warnings << "column #{name} is ambiguous; attached to #{candidates.sort.join(', ')}"
        end
      end

      def resolved_tables(column, sources)
        qualifier = column["table"]
        if present?(qualifier) && sources[qualifier]
          return sources.fetch(qualifier).physical_tables
        end
        return [qualifier] if present?(qualifier) && @columns_by_table.key?(qualifier)
        return [] if present?(qualifier)

        physical = sources.values.uniq.flat_map(&:physical_tables).uniq
        matches = physical.select do |table|
          @columns_by_table.fetch(table, Set.new).include?(column["name"])
        end
        matches.empty? ? physical : matches
      end

      def record_predicates(expression, sources)
        groups = dnf(expression)

        groups.each_with_index do |group, group_index|
          group.each do |term|
            predicate = simple_predicate(term, sources)
            next unless predicate

            predicate[:group] = group_index if groups.length > 1
            @predicates << predicate
          end
        end
      end

      def dnf(node)
        node = node["Nested"] if node.is_a?(Hash) && node.key?("Nested")
        binary = node["BinaryOp"] if node.is_a?(Hash)
        return [[node]] unless binary && %w[And Or].include?(binary["op"])

        left = dnf(binary["left"])
        right = dnf(binary["right"])
        binary["op"] == "Or" ? left + right : left.product(right).map { |a, b| a + b }
      end

      def simple_predicate(node, sources)
        if node.is_a?(Hash) && node.key?("BinaryOp")
          binary = node.fetch("BinaryOp")
          return binary_predicate(binary, sources) if %w[Eq Neq].include?(binary["op"])
        elsif node.is_a?(Hash) && node.key?("InList")
          list = node.fetch("InList")
          values = Array(list["list"]).map { |value| literal_value(value) }
          return if values.any? { |value| value.equal?(UNKNOWN_LITERAL) }

          return build_predicate(
            extract_column(list["expr"]),
            list["negated"] ? "not_in" : "in",
            values,
            sources
          )
        elsif node.is_a?(Hash) && node.key?("IsNull")
          null = node.fetch("IsNull")
          return build_predicate(
            extract_column(null["expr"]),
            null["negated"] ? "not_eq" : "eq",
            [nil],
            sources
          )
        end
      end

      def binary_predicate(binary, sources)
        left = extract_column(binary["left"])
        right = extract_column(binary["right"])

        if left && right
          endpoints = [
            resolved_endpoint(left, sources),
            resolved_endpoint(right, sources)
          ]
          @equality_edges << endpoints.sort.join("=") if endpoints.all?
          return
        end

        column, value_node = left ? [left, binary["right"]] : [right, binary["left"]]
        return unless column

        value = literal_value(value_node)
        return if value.equal?(UNKNOWN_LITERAL)

        build_predicate(
          column,
          binary["op"] == "Eq" ? "eq" : "not_eq",
          [value],
          sources
        )
      end

      def build_predicate(column, operator, values, sources)
        return unless column

        tables = resolved_tables(column, sources)
        return unless tables.one?

        {
          table: tables.first,
          column: column.fetch("name"),
          operator: operator,
          values: values.uniq
        }
      end

      def resolved_endpoint(column, sources)
        tables = resolved_tables(column, sources)
        "#{tables.first}.#{column.fetch('name')}" if tables.one?
      end

      def extract_column(node)
        node["Column"] if node.is_a?(Hash) && node.key?("Column")
      end

      UNKNOWN_LITERAL = Object.new.freeze

      def literal_value(node)
        return nil if node.nil?
        return UNKNOWN_LITERAL unless node.is_a?(Hash)
        return node["StringLiteral"] if node.key?("StringLiteral")
        return numeric_value(node["Number"]) if node.key?("Number")
        return node["Boolean"] if node.key?("Boolean")
        return nil if node.key?("Null")

        if node.key?("UnaryOp") && node["UnaryOp"]["op"] == "Minus"
          value = literal_value(node["UnaryOp"]["expr"])
          return value * -1 unless value.equal?(UNKNOWN_LITERAL)
        end

        UNKNOWN_LITERAL
      end

      def numeric_value(value)
        value.include?(".") ? Float(value) : Integer(value)
      end

      def appendable?(select)
        !select["distinct"] &&
          Array(select["group_by"]).empty? &&
          select["having"].nil? &&
          select["limit"].nil? &&
          select["offset"].nil? &&
          select["fetch_first"].nil?
      end

      def physical_tables_in(node, visible_ctes)
        values = case node
        when Array
          node.flat_map { |child| physical_tables_in(child, visible_ctes) }
        when Hash
          if node.key?("Table")
            table = node.fetch("Table")
            visible_ctes[table["name"]]&.physical_tables ||
              [qualified_table_name(table)]
          else
            node.values.flat_map { |child| physical_tables_in(child, visible_ctes) }
          end
        else
          []
        end

        values.to_a.compact.flatten.uniq
      end

      def normalize_schema(schema)
        schema.to_h.each_with_object({}) do |(table, columns), normalized|
          column_names = columns.respond_to?(:keys) ? columns.keys : Array(columns)
          normalized[table.to_s] = column_names.map(&:to_s).to_set.freeze
        end.freeze
      end

      def normalized_table_columns
        @table_columns
          .transform_values { |columns| columns.to_a.sort }
          .sort
          .to_h
      end

      def normalized_predicates
        @predicates
          .uniq
          .sort_by do |predicate|
            [
              predicate.fetch(:group, -1),
              predicate.fetch(:table),
              predicate.fetch(:column),
              predicate.fetch(:operator),
              predicate.fetch(:values).inspect
            ]
          end
      end

      def qualified_table_name(table)
        [table["catalog"], table["schema"], table["name"]]
          .compact
          .reject(&:empty?)
          .join(".")
      end

      def qualified_column_name(column)
        [column["table"], column["name"]].compact.join(".")
      end

      def node_shape(node)
        node.is_a?(Hash) ? node.keys.first : node.class.name
      end

      def record_column(table, column)
        @table_columns[table.to_s] << column.to_s
      end

      def present?(value)
        !value.nil? && !value.empty?
      end
    end

    class ProjectionPreserver
      def initialize(original, qualified)
        @original = original
        @qualified = qualified
      end

      def call
        restore(@original, @qualified)
        @qualified
      end

      private

      def restore(original, qualified)
        case original
        when Array
          return unless qualified.is_a?(Array) && original.length == qualified.length

          original.zip(qualified).each { |left, right| restore(left, right) }
        when Hash
          return unless qualified.is_a?(Hash)

          if original.key?("Select") && qualified.key?("Select")
            restore_select(original.fetch("Select"), qualified.fetch("Select"))
          else
            original.each do |key, value|
              restore(value, qualified[key]) if qualified.key?(key)
            end
          end
        end
      end

      def restore_select(original, qualified)
        original_columns = Array(original["columns"])
        if original_columns.any? { |column| wildcard?(column) }
          qualified["columns"] = original_columns
        else
          restore(original_columns, qualified["columns"])
        end

        original.each do |key, value|
          next if key == "columns"

          restore(value, qualified[key]) if qualified.key?(key)
        end
      end

      def wildcard?(node)
        node.is_a?(Hash) &&
          (node.key?("Wildcard") || node.key?("QualifiedWildcard"))
      end
    end
    private_constant :ProjectionPreserver

    class ScopeValidator
      def initialize(scope, columns_by_table:, table_columns:)
        @scope = scope
        @columns_by_table = columns_by_table
        @table_columns = table_columns
      end

      def validate!
        @scope.walk.each do |scope|
          validate_sources(scope)
          validate_columns(scope)
        end
      end

      private

      def validate_sources(scope)
        scope.sources.each_value do |source|
          physical_tables(source).each do |table|
            next if @table_columns.key?(table)

            raise UnsupportedError,
              "SQLGlot scope discovered physical table #{table} without a dependency"
          end
        end
      end

      def validate_columns(scope)
        scope.columns.each do |column|
          next if column.name == "*" || column.table.nil?

          source = scope.sources[column.table]
          next unless source

          physical_tables(source).each do |table|
            next unless @columns_by_table.fetch(table, Set.new).include?(column.name)
            next if @table_columns.fetch(table, Set.new).include?(column.name)

            raise UnsupportedError,
              "SQLGlot scope discovered #{table}.#{column.name} without a dependency"
          end
        end
      end

      def physical_tables(source)
        if source.kind == :table
          table = source.table.qualified_name
          @columns_by_table.key?(table) ? [table] : []
        else
          source.scope.walk.flat_map do |scope|
            scope.sources.values.flat_map { |child| physical_tables(child) }
          end.uniq
        end
      end
    end
    private_constant :ScopeValidator
  end
end
