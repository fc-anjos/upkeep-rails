module RefreshSync
  # Extracts membership predicates from a relation's Arel where clause.
  # Deliberately narrow (the Electric restriction): only equality / IN on
  # columns of the relation's own table, with concrete values. Anything else
  # degrades that table to a table-level dependency with a reason.
  # Joined/included association tables always degrade to table-level.
  class RelationAnalysis
    def initialize(relation)
      @relation = relation
      @klass = relation.klass
      @table = @klass.table_name
    end

    def apply_to(recording, membership_only: false)
      read_set = recording.read_set
      node = recording.prov_address
      joined = joined_tables
      predicates, fallback_reason = extract_predicates(joined)
      if fallback_reason
        read_set.record_table(@table, fallback_reason, node: node)
      else
        own = predicates.fetch(@table, {})
        read_set.record_predicate(@table, own, node: node, membership_only: membership_only)
        # A predicate binding an identity-scoped column marks the whole
        # capture identity-bound: its surfaces stay Tier P.
        recording.identity_bound! if (own.keys & RefreshSync.identity_columns).any?
      end
      joined.each do |t|
        # A joined table whose OWN columns are constrained by simple
        # conditions gets those as its predicate (a row can only enter or
        # leave the join result by satisfying them before or after the
        # write — the verdict layer checks both sides). No conditions, or
        # any analysis fallback: the whole joined table stays a dependency.
        pred = fallback_reason ? nil : predicates[t]
        if pred&.any?
          read_set.record_predicate(t, pred, node: node, membership_only: membership_only)
          recording.identity_bound! if (pred.keys & RefreshSync.identity_columns).any?
        else
          read_set.record_table(t, :joined_table, node: node)
        end
      end
    end

    private

    # {table_name => predicate} for the relation's own table and any joined
    # tables; a condition on any OTHER table (aliases, subqueries) means
    # the analysis can't vouch for the mapping and everything degrades.
    def extract_predicates(joined)
      allowed = [@table] + joined
      predicates = {}
      nodes = flatten(@relation.where_clause.ast)
      nodes.each do |node|
        table, attr, values = simple_condition(node, allowed)
        return [nil, :"unanalyzable_#{node.class.name.demodulize.underscore}"] unless attr
        ((predicates[table] ||= {})[attr] ||= []).concat(values)
      end
      [predicates, nil]
    rescue => e
      [nil, :"analysis_error_#{e.class.name.demodulize.underscore}"]
    end

    def flatten(node)
      case node
      when nil then []
      when Arel::Nodes::And then node.children.flat_map { |c| flatten(c) }
      else [node]
      end
    end

    # Returns [table, attr_name, values] for supported nodes, nil otherwise.
    def simple_condition(node, allowed)
      case node
      when Arel::Nodes::Equality
        table, attr = attribute_of(node.left, allowed)
        return nil unless attr
        value = literal_value(node.right)
        value == :opaque ? nil : [table, attr, [value]]
      when Arel::Nodes::HomogeneousIn
        return nil unless node.type == :in
        table, attr = attribute_of(node.attribute, allowed)
        return nil unless attr
        [table, attr, node.casted_values]
      when Arel::Nodes::In
        table, attr = attribute_of(node.left, allowed)
        return nil unless attr
        values = Array(node.right).map { |v| literal_value(v) }
        values.include?(:opaque) ? nil : [table, attr, values]
      end
    end

    def attribute_of(node, allowed)
      return nil unless node.is_a?(Arel::Attributes::Attribute)
      return nil unless node.relation.respond_to?(:name)
      table = node.relation.name
      return nil unless allowed.include?(table)
      [table, node.name.to_s]
    end

    def literal_value(node)
      case node
      when Arel::Nodes::BindParam
        literal_value(node.value)
      when ActiveModel::Attribute # Rails 8.1: Equality#right is a bare QueryAttribute
        node.value
      when Arel::Nodes::Casted, Arel::Nodes::Quoted
        node.value
      when Numeric, String, TrueClass, FalseClass
        node
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
        else
          tables << "__unknown_join__"
        end
      end
      tables.uniq
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
