# frozen_string_literal: true

require "json"

module Upkeep
  module SQLGlot
    class Error < StandardError; end
    class LibraryNotFoundError < Error; end
    class ParseError < Error; end
    class TranspileError < Error; end
    class GenerateError < Error; end
    class SemanticError < Error; end
  end
end

require_relative "sqlglot/native"

module Upkeep
  module SQLGlot
    module Dialect
      NAMES = %w[
        ansi athena bigquery clickhouse databricks doris dremio drill druid
        duckdb exasol fabric hive materialize mysql oracle postgres presto prql
        redshift risingwave singlestore snowflake spark sqlite starrocks tableau
        teradata trino tsql
      ].freeze
      ALIASES = {
        "mariadb" => "mysql",
        "mssql" => "tsql",
        "postgresql" => "postgres",
        "sqlserver" => "tsql"
      }.freeze

      module_function

      def resolve(name)
        return nil if name.nil?

        key = name.to_s.downcase.strip
        return key if NAMES.include?(key)
        return ALIASES.fetch(key) if ALIASES.key?(key)

        raise ArgumentError, "Unknown SQL dialect: #{name.inspect}"
      end
    end

    ColumnRef = Data.define(:table, :name) do
      def self.from_native(value)
        new(table: value["table"], name: value.fetch("name"))
      end
    end

    TableRef = Data.define(
      :catalog,
      :schema,
      :name,
      :alias,
      :name_quote_style,
      :alias_quote_style
    ) do
      def self.from_native(value)
        new(
          catalog: value["catalog"],
          schema: value["schema"],
          name: value.fetch("name"),
          alias: value["alias"],
          name_quote_style: value["name_quote_style"],
          alias_quote_style: value["alias_quote_style"]
        )
      end

      def qualified_name
        [catalog, schema, name].compact.reject(&:empty?).join(".")
      end
    end

    Source = Data.define(:kind, :table, :scope) do
      def self.from_native(value)
        case value.fetch("kind")
        when "table"
          new(
            kind: :table,
            table: TableRef.from_native(value.fetch("table")),
            scope: nil
          )
        when "scope"
          new(
            kind: :scope,
            table: nil,
            scope: Scope.from_native(value.fetch("scope"))
          )
        else
          raise KeyError, "Unknown SQLGlot source kind: #{value["kind"].inspect}"
        end
      end
    end

    Scope = Data.define(
      :scope_type,
      :sources,
      :columns,
      :external_columns,
      :derived_table_scopes,
      :subquery_scopes,
      :union_scopes,
      :cte_scopes,
      :selected_sources,
      :is_correlated
    ) do
      def self.from_native(value)
        new(
          scope_type: value.fetch("scope_type").to_sym,
          sources: sources_from_native(value.fetch("sources")),
          columns: columns_from_native(value.fetch("columns")),
          external_columns: columns_from_native(value.fetch("external_columns")),
          derived_table_scopes: scopes_from_native(
            value.fetch("derived_table_scopes")
          ),
          subquery_scopes: scopes_from_native(value.fetch("subquery_scopes")),
          union_scopes: scopes_from_native(value.fetch("union_scopes")),
          cte_scopes: scopes_from_native(value.fetch("cte_scopes")),
          selected_sources: sources_from_native(value.fetch("selected_sources")),
          is_correlated: value.fetch("is_correlated")
        )
      end

      def child_scopes
        derived_table_scopes + subquery_scopes + union_scopes + cte_scopes
      end

      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        child_scopes.each { |child| child.walk(&block) }
      end

      class << self
        private

        def columns_from_native(value)
          value.map { |column| ColumnRef.from_native(column) }.freeze
        end

        def sources_from_native(value)
          value.to_h.transform_values { |source| Source.from_native(source) }
            .freeze
        end

        def scopes_from_native(value)
          value.map { |scope| from_native(scope) }.freeze
        end
      end
    end

    LineageConfig = Data.define(:dialect, :trim_qualifiers, :sources) do
      def initialize(dialect: nil, trim_qualifiers: true, sources: {})
        super(
          dialect: Dialect.resolve(dialect) || "ansi",
          trim_qualifiers: !!trim_qualifiers,
          sources: sources.to_h.transform_keys(&:to_s).transform_values(&:to_s)
            .freeze
        )
      end

      def with_sources(value)
        with(sources: value)
      end

      def with_trim_qualifiers(value)
        with(trim_qualifiers: value)
      end

      def to_h
        {
          dialect: dialect,
          trim_qualifiers: trim_qualifiers,
          sources: sources
        }
      end
    end

    LineageNode = Data.define(
      :name,
      :expression,
      :source_name,
      :source,
      :downstream,
      :alias,
      :depth
    ) do
      def self.from_native(value)
        new(
          name: value.fetch("name"),
          expression: value["expression"],
          source_name: value["source_name"],
          source: value["source"],
          downstream: value.fetch("downstream").map { |child| from_native(child) }
            .freeze,
          alias: value["alias"],
          depth: value.fetch("depth")
        )
      end

      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        downstream.each { |child| child.walk(&block) }
      end

      def source_tables
        walk.filter_map(&:source_name).uniq.sort
      end
    end

    LineageGraph = Data.define(:node, :sql, :dialect) do
      def self.from_native(value)
        new(
          node: LineageNode.from_native(value.fetch("node")),
          sql: value["sql"],
          dialect: value.fetch("dialect").downcase.to_sym
        )
      end

      def source_tables
        node.source_tables
      end

      def walk(&block)
        node.walk(&block)
      end
    end

    class MappingSchema
      attr_reader :dialect

      def initialize(mapping = {}, dialect: nil)
        @dialect = Dialect.resolve(dialect) || "ansi"
        @mapping = deep_freeze(stringify_mapping(mapping.to_h))
        @tables = flatten_tables(@mapping).freeze
        freeze
      end

      def to_native
        {
          tables: @tables.map do |path, columns|
            {
              path: path,
              columns: columns.map do |name, data_type|
                {name: name, data_type: data_type}
              end
            }
          end
        }
      end

      private

      def flatten_tables(node, prefix = [])
        node.each_with_object([]) do |(name, value), tables|
          path = prefix + Array(name)
          unless (1..3).cover?(path.length)
            raise ArgumentError,
              "Schema table paths must contain one to three identifiers: " \
              "#{path.inspect}"
          end

          if column_mapping?(value)
            columns = value.map { |column, data_type| [column, data_type.to_s] }
            tables << [path.freeze, columns.freeze]
          else
            tables.concat(flatten_tables(value, path))
          end
        end
      end

      def column_mapping?(value)
        return true if value.empty?

        nested = value.values.count { |item| item.is_a?(Hash) }
        return false if nested == value.length
        return true if nested.zero?

        raise ArgumentError,
          "Schema mappings cannot mix namespaces and columns at one level"
      end

      def stringify_mapping(value)
        value.each_with_object({}) do |(key, item), result|
          string_key = if key.is_a?(Array)
            key.map { |part| part.to_s.freeze }.freeze
          else
            key.to_s
          end
          result[string_key] = item.is_a?(Hash) ? stringify_mapping(item) : item.to_s
        end
      end

      def deep_freeze(value)
        value.each do |key, item|
          key.freeze
          item.is_a?(Hash) ? deep_freeze(item) : item.freeze
        end
        value.freeze
      end
    end

    module_function

    def parse(sql, dialect: nil)
      JSON.parse(Native.parse(sql.to_s, Dialect.resolve(dialect)))
    end

    def transpile(sql, from: nil, to: nil)
      Native.transpile(
        sql.to_s,
        Dialect.resolve(from),
        Dialect.resolve(to)
      )
    end

    def generate(statement, dialect: nil)
      Native.generate(JSON.generate(statement), Dialect.resolve(dialect))
    end

    def version
      Native.version
    end

    def qualify_columns(statement, schema)
      JSON.parse(
        Native.qualify_columns(
          JSON.generate(statement),
          JSON.generate(schema.to_native),
          schema.dialect
        )
      )
    end

    def build_scope(statement)
      Scope.from_native(
        JSON.parse(Native.build_scope(JSON.generate(statement)))
      )
    end

    def lineage(column, statement, schema, config = nil)
      config ||= LineageConfig.new(dialect: schema.dialect)
      LineageGraph.from_native(
        JSON.parse(
          Native.lineage(
            column.to_s,
            JSON.generate(statement),
            JSON.generate(schema.to_native),
            JSON.generate(config.to_h)
          )
        )
      )
    end
  end
end
