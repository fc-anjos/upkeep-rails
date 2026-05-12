# frozen_string_literal: true

require "active_record"

module Upkeep
  module ActiveRecordQuery
    Result = Data.define(
      :primary_table,
      :table_columns,
      :coverage,
      :sql,
      :primary_key,
      :appendable
    ) do
      def tables
        return [] if coverage == :database

        table_columns.keys.sort
      end

      def appendable?
        appendable
      end
    end

    module_function

    def analyze(relation)
      collector = Collector.new(relation)
      collector.analyze
    end

    class Collector
      def initialize(relation)
        @relation = relation
        @primary_table = relation.klass.table_name
        @primary_key = relation.klass.primary_key
        @table_columns = Hash.new { |hash, table| hash[table] = [] }
        @table_aliases = {}
        @opaque_columns = false
        @opaque_tables = false
      end

      def analyze
        table(@primary_table)
        collect_relation_shape

        Result.new(
          primary_table: @primary_table,
          table_columns: normalized_table_columns,
          coverage: coverage,
          sql: safe_sql,
          primary_key: @primary_key,
          appendable: appendable_relation?
        )
      end

      private

      def collect_relation_shape
        ast = @relation.arel.ast

        ast.cores.each do |core|
          walk(core.source, source: true)
          walk(core.wheres)
          walk(core.groups)
          walk(core.havings)
        end

        walk(ast.orders)
        walk(ast.with) if ast.respond_to?(:with)
      rescue StandardError
        @opaque_tables = true
      end

      def coverage
        return :database if @opaque_tables
        return :tables if @opaque_columns

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
        when Arel::Attributes::Attribute
          attribute(value)
        when Arel::Table
          table(value.name)
        when Arel::Nodes::TableAlias
          table_alias(value)
        when Arel::Nodes::StringJoin
          @opaque_tables = true
        when Arel::Nodes::BoundSqlLiteral, Arel::Nodes::SqlLiteral
          source ? @opaque_tables = true : @opaque_columns = true
        when String
          source ? @opaque_tables = true : @opaque_columns = true
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
        return @opaque_tables = true unless table_name
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
        return @opaque_tables = true unless table_name

        @table_aliases[value.right.to_s] = table_name
        table(table_name)
      end

      def table(name)
        @table_columns[name.to_s]
      end

      def column(table_name, column_name)
        @table_columns[table_name.to_s] << column_name.to_s
      end

      def safe_sql
        @relation.to_sql
      rescue StandardError => error
        "#{error.class}: #{error.message}"
      end
    end
  end
end
