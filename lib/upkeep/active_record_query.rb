# frozen_string_literal: true

require "active_record"

module Upkeep
  module ActiveRecordQuery
    UNKNOWN_PREDICATE_VALUE = Object.new.freeze

    class OpaqueRelationError < StandardError
      attr_reader :model_name, :table_name, :sql, :reasons

      def initialize(relation, reasons:)
        @model_name = relation.klass.name
        @table_name = relation.klass.table_name
        @sql = relation.to_sql
        @reasons = reasons

        super(build_message)
      rescue StandardError => error
        super("Upkeep cannot prove this Active Record relation's structural dependencies: #{error.message}")
      end

      private

      def build_message
        <<~MESSAGE
          Upkeep cannot make this Active Record relation reactive because its query shape is opaque.

          Relation:
            #{model_name} (#{table_name})

          SQL:
            #{sql}

          Why:
          #{reasons.map { |reason| "            - #{reason}" }.join("\n")}

          What to do:
            - Rewrite raw SQL predicates with structural Active Record hash or Arel predicates.
            - Rewrite raw SQL joins or FROM sources with structural Active Record/Arel joins.
            - Render this boundary outside Upkeep reactivity when the query cannot expose its sources.
        MESSAGE
      end

      public

      def suggestions
        [
          "Rewrite raw SQL predicates with structural Active Record hash or Arel predicates.",
          "Rewrite raw SQL joins or FROM sources with structural Active Record/Arel joins.",
          "Render this boundary outside Upkeep reactivity when the query cannot expose its sources."
        ]
      end
    end

    Result = Data.define(
      :primary_table,
      :table_columns,
      :coverage,
      :sql,
      :primary_key,
      :appendable,
      :limit_value,
      :predicates
    ) do
      def tables = table_columns.keys.sort

      def appendable?
        appendable
      end
    end

    module_function

    def analyze(relation, opaque_table_policy: :raise)
      collector = Collector.new(relation, opaque_table_policy: opaque_table_policy)
      collector.analyze
    end

    class Collector
      def initialize(relation, opaque_table_policy:)
        @relation = relation
        @opaque_table_policy = opaque_table_policy
        @primary_table = relation.klass.table_name
        @primary_key = relation.klass.primary_key
        @table_columns = Hash.new { |hash, table| hash[table] = [] }
        @table_aliases = {}
        @opaque_columns = false
        @opaque_tables = false
        @opaque_table_reasons = []
        @opaque_column_reasons = []
        @predicate_groups = []
      end

      def analyze
        table(@primary_table)
        collect_relation_shape
        raise_opaque_relation! if opaque_relation? && @opaque_table_policy == :raise

        Result.new(
          primary_table: @primary_table,
          table_columns: normalized_table_columns,
          coverage: coverage,
          sql: safe_sql,
          primary_key: @primary_key,
          appendable: appendable_relation?,
          limit_value: @relation.limit_value,
          predicates: normalized_predicates
        )
      end

      private

      def collect_relation_shape
        ast = @relation.arel.ast

        ast.cores.each do |core|
          walk(core.source, source: true)
          walk(core.wheres)
          record_predicate_groups(core.wheres)
          walk(core.groups)
          walk(core.havings)
        end

        walk(ast.orders)
        walk(ast.with) if ast.respond_to?(:with)
      rescue StandardError => error
        opaque_table!("relation AST could not be inspected (#{error.class}: #{error.message})")
      end

      def coverage
        return :tables if @opaque_tables || @opaque_columns

        :columns
      end

      def normalized_table_columns
        table(@primary_table)
        column(@primary_table, @primary_key) if @primary_key

        @table_columns.transform_values { |columns| columns.compact.uniq.sort }.sort.to_h
      end

      def appendable_relation?
        return false unless coverage == :columns
        return false if @opaque_tables
        return false if @relation.limit_value || @relation.offset_value
        return false if @relation.distinct_value
        return false if @relation.group_values.any?
        return false if !@relation.having_clause.empty?

        true
      end

      def walk(value, source: false)
        case value
        when nil, true, false, Numeric, Symbol, Class, Module
          nil
        when Array
          value.each { |entry| walk(entry, source: source) }
        when Hash
          value.each_value { |entry| walk(entry, source: source) }
        when defined?(Arel::Nodes::Quoted) && Arel::Nodes::Quoted
          nil
        when defined?(Arel::Nodes::Casted) && Arel::Nodes::Casted
          nil
        when Arel::Attributes::Attribute
          attribute(value)
        when Arel::Nodes::Equality
          walk(value.left, source: source)
          walk(value.right, source: source) if value.right.is_a?(Arel::Attributes::Attribute)
        when defined?(Arel::Nodes::NotEqual) && Arel::Nodes::NotEqual
          walk(value.left, source: source)
          walk(value.right, source: source) if value.right.is_a?(Arel::Attributes::Attribute)
        when Arel::Nodes::HomogeneousIn
          walk(value.attribute, source: source)
        when defined?(Arel::Nodes::In) && Arel::Nodes::In
          walk(value.left, source: source)
          walk(value.right, source: source) if value.right.is_a?(Arel::Attributes::Attribute)
        when Arel::Nodes::Matches, Arel::Nodes::DoesNotMatch
          walk(value.left, source: source)
          walk(value.right, source: source) if value.right.is_a?(Arel::Attributes::Attribute)
        when Arel::Nodes::NamedFunction
          walk(value.expressions, source: source)
        when Arel::Nodes::InfixOperation
          # Operator-style expressions (jsonb `->>`/`#>>`, arithmetic, etc.). The reactive
          # surface is the operands; the operator itself is a SQL token, not a data
          # dependency, so walk left/right and ignore the operator (mirrors NamedFunction).
          walk(value.left, source: source)
          walk(value.right, source: source)
        when Arel::Table
          table(value.name)
        when Arel::Nodes::TableAlias
          table_alias(value)
        when Arel::Nodes::StringJoin
          opaque_table!("raw SQL join")
        when Arel::Nodes::BoundSqlLiteral, Arel::Nodes::SqlLiteral
          source ? opaque_table!("raw SQL source") : opaque_column!("raw SQL predicate or order expression")
        when String
          source ? opaque_table!("string SQL source") : opaque_column!("string SQL predicate or order expression")
        else
          walk_arel_node(value, source: source)
        end
      end

      def walk_arel_node(value, source:)
        return unless value.is_a?(Arel::Nodes::Node)

        value.instance_variables.each do |ivar|
          walk(value.instance_variable_get(ivar), source: source)
        end
      end

      def attribute(value)
        table_name = table_name_for(value.relation)
        return opaque_table!("attribute references an unknown table source") unless table_name
        return if value.name.to_s == "*"

        column(table_name, value.name)
      end

      def table_name_for(relation)
        if relation.is_a?(Arel::Nodes::TableAlias)
          table_name_for(relation.left)
        elsif relation.respond_to?(:name)
          name = relation.name.to_s
          @table_aliases.fetch(name, name)
        elsif relation.respond_to?(:left)
          table_name_for(relation.left)
        end
      end

      def table_alias(value)
        table_name = table_name_for(value.left)
        return opaque_table!("table alias references an unknown table source") unless table_name

        @table_aliases[value.right.to_s] = table_name
        table(table_name)
      end

      def opaque_table!(reason)
        @opaque_tables = true
        @opaque_table_reasons << reason
      end

      def opaque_column!(reason)
        @opaque_columns = true
        @opaque_column_reasons << reason
      end

      def opaque_relation?
        @opaque_tables || @opaque_columns
      end

      def raise_opaque_relation!
        raise OpaqueRelationError.new(@relation, reasons: (@opaque_table_reasons + @opaque_column_reasons).uniq)
      end

      def table(name)
        @table_columns[name.to_s]
      end

      def column(table_name, column_name)
        @table_columns[table_name.to_s] << column_name.to_s
      end

      def record_predicate_groups(value)
        groups = predicate_groups_for(value)
        return if groups.empty?

        @predicate_groups = and_predicate_groups(@predicate_groups, groups)
      end

      def predicate_groups_for(value)
        case value
        when nil, true, false, Numeric, Symbol, Class, Module, String
          []
        when Array
          value.reduce([]) do |groups, entry|
            and_predicate_groups(groups, predicate_groups_for(entry))
          end
        when Hash
          predicate_groups_for(value.values)
        when Arel::Nodes::Equality
          group_for_predicate(predicate_for(value.left, "eq", [predicate_value(value.right)]))
        when defined?(Arel::Nodes::NotEqual) && Arel::Nodes::NotEqual
          group_for_predicate(predicate_for(value.left, "not_eq", [predicate_value(value.right)]))
        when Arel::Nodes::HomogeneousIn
          group_for_predicate(predicate_for(value.attribute, homogeneous_in_operator(value), Array(value.values).map { |entry| predicate_value(entry) }))
        when defined?(Arel::Nodes::In) && Arel::Nodes::In
          group_for_predicate(predicate_for(value.left, "in", Array(value.right).map { |entry| predicate_value(entry) }))
        when Arel::Nodes::Grouping
          predicate_groups_for(value.expr)
        when Arel::Nodes::And
          predicate_groups_for(value.children)
        when Arel::Nodes::Or
          child_groups = or_children(value).map { |child| predicate_groups_for(child) }
          return [] if child_groups.any?(&:empty?)

          child_groups.flatten(1)
        else
          []
        end
      end

      def homogeneous_in_operator(node)
        node.respond_to?(:type) && node.type.to_sym == :notin ? "not_in" : "in"
      end

      def or_children(node)
        if node.respond_to?(:children)
          node.children
        else
          [node.left, node.right]
        end
      end

      def group_for_predicate(predicate)
        predicate ? [[predicate]] : []
      end

      def and_predicate_groups(left_groups, right_groups)
        return right_groups if left_groups.empty?
        return left_groups if right_groups.empty?

        left_groups.flat_map do |left_group|
          right_groups.map { |right_group| left_group + right_group }
        end
      end

      def predicate_for(attribute, operator, values)
        return unless attribute.is_a?(Arel::Attributes::Attribute)

        table_name = table_name_for(attribute.relation)
        return unless table_name

        values = values.reject { |value| value.equal?(UNKNOWN_PREDICATE_VALUE) }
        return if values.empty?

        {
          table: table_name.to_s,
          column: attribute.name.to_s,
          operator: operator,
          values: values.uniq
        }
      end

      def predicate_value(value)
        if value.respond_to?(:value_for_database)
          value.value_for_database
        elsif value.respond_to?(:value)
          value.value
        elsif value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.is_a?(Symbol)
          value
        else
          UNKNOWN_PREDICATE_VALUE
        end
      end

      def normalized_predicates
        grouped = normalized_predicate_groups
        predicates = if grouped.one?
          grouped.first
        else
          grouped.each_with_index.flat_map do |group, index|
            group.map { |predicate| predicate.merge(group: index) }
          end
        end

        predicates
          .uniq
          .sort_by { |predicate| [predicate.fetch(:group, -1), predicate.fetch(:table), predicate.fetch(:column), predicate.fetch(:operator), predicate.fetch(:values).inspect] }
      end

      def normalized_predicate_groups
        @predicate_groups
          .map do |group|
            group
              .uniq
              .sort_by { |predicate| [predicate.fetch(:table), predicate.fetch(:column), predicate.fetch(:operator), predicate.fetch(:values).inspect] }
          end
          .uniq
      end

      def safe_sql
        @relation.to_sql
      rescue StandardError => error
        "#{error.class}: #{error.message}"
      end
    end
  end
end
