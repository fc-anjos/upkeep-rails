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

    def apply_to(recording)
      read_set = recording.read_set
      node = recording.prov_address
      predicate, fallback_reason = extract_predicate
      if fallback_reason
        read_set.record_table(@table, fallback_reason, node: node)
      else
        read_set.record_predicate(@table, predicate, node: node)
        # A predicate binding an identity-scoped column marks the whole
        # capture identity-bound: its surfaces stay Tier P.
        recording.identity_bound! if (predicate.keys & RefreshSync.identity_columns).any?
      end
      joined_tables.each { |t| read_set.record_table(t, :joined_table, node: node) }
    end

    private

    def extract_predicate
      predicate = {}
      nodes = flatten(@relation.where_clause.ast)
      nodes.each do |node|
        attr, values = simple_condition(node)
        return [nil, :"unanalyzable_#{node.class.name.demodulize.underscore}"] unless attr
        (predicate[attr] ||= []).concat(values)
      end
      [predicate, nil]
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

    # Returns [attr_name, values] for supported nodes, nil otherwise.
    def simple_condition(node)
      case node
      when Arel::Nodes::Equality
        attr = own_attribute(node.left) or return nil
        value = literal_value(node.right)
        value == :opaque ? nil : [attr, [value]]
      when Arel::Nodes::HomogeneousIn
        return nil unless node.type == :in
        attr = own_attribute(node.attribute) or return nil
        [attr, node.casted_values]
      when Arel::Nodes::In
        attr = own_attribute(node.left) or return nil
        values = Array(node.right).map { |v| literal_value(v) }
        values.include?(:opaque) ? nil : [attr, values]
      end
    end

    def own_attribute(node)
      return nil unless node.is_a?(Arel::Attributes::Attribute)
      return nil unless node.relation.respond_to?(:name) && node.relation.name == @table
      node.name.to_s
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
          reflection = @klass.reflect_on_association(join)
          tables << (reflection ? reflection.table_name : "__unknown_join__")
        when Hash
          join.each_key do |key|
            reflection = @klass.reflect_on_association(key)
            tables << (reflection ? reflection.table_name : "__unknown_join__")
          end
        else
          tables << "__unknown_join__"
        end
      end
      tables.uniq
    end
  end
end
