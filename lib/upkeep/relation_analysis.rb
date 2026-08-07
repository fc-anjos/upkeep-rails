module Upkeep
  # Extracts membership predicates from a relation's Arel where clause.
  # Two tiers of understanding:
  #   - simple equality / IN on columns of the relation's own table, with
  #     concrete values (the original Electric restriction), and
  #   - raw SQL fragments (where("start_date <= ?", ...)) parsed once per
  #     shape through SqlAnalysis into structured predicates — matchable,
  #     and (for plain comparisons/boolean logic) evaluable.
  # Anything neither tier can vouch for degrades that table to a
  # table-level dependency with a reason, exactly as before the parser
  # existed. Joined/included association tables degrade to table-level;
  # string JOIN clauses resolve their aliases and subqueries to physical
  # tables through the parser, falling back to the unknown-join degrade.
  class RelationAnalysis
    def initialize(relation)
      @relation = relation
      @klass = relation.klass
      @table = @klass.table_name
    end

    def apply_to(recording, membership_only: false)
      @recording = recording
      @membership_only = membership_only
      joined = joined_tables
      predicates, fragments, fallback_reason = extract_predicates(joined)
      if fallback_reason
        read_set.record_table(@table, fallback_reason, node: node)
        Legibility.note_hint(@table, fallback_reason)
      else
        record_own(predicates.fetch(@table, {}), fragments)
      end
      joined.each { |t| record_joined(t, fallback_reason ? nil : predicates[t]) }
    end

    private

    def read_set = @recording.read_set
    def node = @recording.prov_address

    def record_own(own, fragments)
      read_set.record_predicate(@table, own, node: node, membership_only: @membership_only)
      # A predicate binding an identity-scoped column marks the whole
      # capture identity-bound: its surfaces stay Tier P.
      note_identity(own.keys)
      fragments.each do |fragment|
        read_set.record_predicate(@table, fragment, node: node, membership_only: @membership_only)
        note_identity(fragment.fetch("__fragment__").fetch("columns"))
      end
    end

    def note_identity(columns)
      @recording.identity_bound! if (columns.map(&:to_s) & Upkeep.identity_columns).any?
    end

    # A joined table whose OWN columns are constrained by simple conditions
    # gets those as its predicate (a row can only enter or leave the join
    # result by satisfying them before or after the write — the verdict
    # layer checks both sides). No conditions, or any analysis fallback:
    # the whole joined table stays a dependency.
    def record_joined(table, pred)
      if pred&.any?
        read_set.record_predicate(table, pred, node: node, membership_only: @membership_only)
        note_identity(pred.keys)
      else
        read_set.record_table(table, :joined_table, node: node)
      end
    end

    # [{table => hash_predicate}, [fragment...], fallback_reason] — the
    # fragments always belong to the relation's own table; a condition on
    # any OTHER table (aliases, subqueries) means the analysis can't vouch
    # for the mapping and everything degrades.
    def extract_predicates(joined)
      allowed = [@table] + joined
      predicates = {}
      fragments = []
      flatten(@relation.where_clause.ast).each do |where_node|
        next if absorb_condition(where_node, allowed, predicates, fragments)
        return [nil, nil, :"unanalyzable_#{where_node.class.name.demodulize.underscore}"]
      end
      [predicates, fragments, nil]
    rescue => e
      [nil, nil, :"analysis_error_#{e.class.name.demodulize.underscore}"]
    end

    def absorb_condition(where_node, allowed, predicates, fragments)
      table, attr, values = simple_condition(where_node, allowed)
      if attr
        ((predicates[table] ||= {})[attr] ||= []).concat(values)
        return true
      end
      fragment = fragment_condition(where_node, allowed)
      fragments << fragment if fragment
      fragment
    end

    def flatten(where_node)
      case where_node
      when nil then []
      when Arel::Nodes::And then where_node.children.flat_map { |c| flatten(c) }
      else [where_node]
      end
    end

    # A raw-SQL where condition, parsed (once per shape, via the capped
    # SqlAnalysis cache) into a structured predicate on the relation's own
    # table. Joined tables and their aliases are "covered": a condition on
    # them evaluates as UNKNOWN but does not degrade (the joined table is a
    # table-level dependency anyway). nil - not a SQL fragment, or one the
    # parser cannot vouch for (the caller then degrades as before).
    def fragment_condition(where_node, allowed)
      sql, binds = SqlAnalysis.arel_fragment(where_node)
      return nil unless sql
      compiled = SqlAnalysis.fragment(
        sql, table: @table, binds: binds,
        aliases: @join_aliases || {}, covered: allowed - [@table]
      )
      compiled && { "__fragment__" => compiled }
    end

    # Returns [table, attr_name, values] for supported nodes, nil otherwise.
    def simple_condition(where_node, allowed)
      case where_node
      when Arel::Nodes::Equality then equality_condition(where_node, allowed)
      when Arel::Nodes::HomogeneousIn then homogeneous_in_condition(where_node, allowed)
      when Arel::Nodes::In then in_condition(where_node, allowed)
      end
    end

    def equality_condition(where_node, allowed)
      table, attr = attribute_of(where_node.left, allowed)
      return nil unless attr
      value = literal_value(where_node.right)
      value == :opaque ? nil : [table, attr, [value]]
    end

    def homogeneous_in_condition(where_node, allowed)
      return nil unless where_node.type == :in
      table, attr = attribute_of(where_node.attribute, allowed)
      attr && [table, attr, where_node.casted_values]
    end

    def in_condition(where_node, allowed)
      table, attr = attribute_of(where_node.left, allowed)
      return nil unless attr
      values = Array(where_node.right).map { |v| literal_value(v) }
      values.include?(:opaque) ? nil : [table, attr, values]
    end

    def attribute_of(where_node, allowed)
      return nil unless where_node.is_a?(Arel::Attributes::Attribute)
      return nil unless where_node.relation.respond_to?(:name)
      table = where_node.relation.name
      return nil unless allowed.include?(table)
      [table, where_node.name.to_s]
    end

    def literal_value(where_node)
      case where_node
      when Arel::Nodes::BindParam
        literal_value(where_node.value)
      when ActiveModel::Attribute # Rails 8.1: Equality#right is a bare QueryAttribute
        where_node.value
      when Arel::Nodes::Casted, Arel::Nodes::Quoted
        where_node.value
      when Numeric, String, TrueClass, FalseClass
        where_node
      else :opaque
      end
    end

    def joined_tables
      tables = []
      (@relation.joins_values + @relation.includes_values + @relation.eager_load_values).each do |join|
        case join
        when Symbol
          tables << reflection_table(@klass.reflect_on_association(join))
        when Hash
          join.each_key do |key|
            tables << reflection_table(@klass.reflect_on_association(key))
          end
        when String
          tables.concat(string_join_tables(join))
        else
          tables << "__unknown_join__"
        end
      end
      tables.uniq
    end

    # A string JOIN clause ("LEFT JOIN (SELECT ...) latest_reviews ON ...")
    # resolved through the parser: every physical table it reads — through
    # aliases and subqueries — becomes a table-level dependency under its
    # real name, and the alias map lets fragment conditions on those
    # aliases stay covered. Unresolvable: the unknown-join degrade, as
    # before.
    def string_join_tables(join)
      analysis = SqlAnalysis.join_analysis(@table, join)
      return ["__unknown_join__"] unless analysis
      @join_aliases = (@join_aliases || {}).merge(analysis[:aliases])
      analysis[:tables]
    end

    # Polymorphic reflections cannot compute a class/table statically
    # (reflection.table_name raises); rows actually loaded through them are
    # still recorded by the instantiation hook, so degrade the join itself
    # to the unknown marker instead of crashing the render.
    def reflection_table(reflection)
      return "__unknown_join__" unless reflection
      return "__unknown_join__" if reflection.polymorphic?
      reflection.table_name
    rescue ArgumentError, NameError
      "__unknown_join__"
    end
  end
end
