# frozen_string_literal: true

require "sqlglot"
require_relative "sqlglot_semantics/native"

module Sqlglot
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
      if value.key?("Table")
        new(kind: :table, table: TableRef.from_native(value.fetch("Table")), scope: nil)
      else
        new(kind: :scope, table: nil, scope: Scope.from_native(value.fetch("Scope")))
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
        columns: value.fetch("columns").map { |column| ColumnRef.from_native(column) },
        external_columns: value.fetch("external_columns").map { |column| ColumnRef.from_native(column) },
        derived_table_scopes: scopes_from_native(value.fetch("derived_table_scopes")),
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

      def sources_from_native(value)
        value.to_h.transform_values { |source| Source.from_native(source) }.freeze
      end

      def scopes_from_native(value)
        value.map { |scope| from_native(scope) }.freeze
      end
    end
  end

  LineageConfig = Data.define(:dialect, :trim_qualifiers, :sources) do
    def initialize(dialect: nil, trim_qualifiers: true, sources: {})
      resolved = Sqlglot::Dialect.resolve(dialect) || "ansi"
      super(
        dialect: resolved,
        trim_qualifiers: !!trim_qualifiers,
        sources: sources.to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
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
        downstream: value.fetch("downstream").map { |child| from_native(child) }.freeze,
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
    attr_reader :dialect, :mapping

    def initialize(mapping = {}, dialect: nil)
      @dialect = Sqlglot::Dialect.resolve(dialect) || "ansi"
      @mapping = {}
      mapping.to_h.each { |table, columns| replace_table(table, columns) }
    end

    def replace_table(table_path, columns)
      @mapping[normalize_path(table_path)] = normalize_columns(columns)
      self
    end

    def add_table(table_path, columns)
      path = normalize_path(table_path)
      raise ArgumentError, "Table already exists: #{path}" if @mapping.key?(path)

      @mapping[path] = normalize_columns(columns)
      self
    end

    def remove_table(table_path)
      !@mapping.delete(normalize_path(table_path)).nil?
    end

    def table_names
      @mapping.keys.sort.map do |path|
        parts = path.split(".")
        ([""] * (3 - parts.length)) + parts
      end
    end

    def column_names(table_path)
      fetch_table(table_path).keys
    end

    def get_column_type(table_path, column)
      fetch_table(table_path).fetch(column.to_s)
    end

    def has_column(table_path, column)
      fetch_table(table_path).key?(column.to_s)
    rescue KeyError
      false
    end

    private

    def fetch_table(table_path)
      @mapping.fetch(normalize_path(table_path))
    end

    def normalize_path(table_path)
      Array(table_path.is_a?(String) ? table_path.split(".") : table_path)
        .map(&:to_s)
        .join(".")
    end

    def normalize_columns(columns)
      if columns.respond_to?(:keys)
        columns.to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
      else
        Array(columns).to_h { |column| [column.to_s, "UNKNOWN"] }.freeze
      end
    end
  end

  class << self
    def qualify_columns(statement, schema)
      Upkeep::SqlglotSemantics::Native.qualify_columns(statement, schema)
    end

    def build_scope(statement)
      Scope.from_native(Upkeep::SqlglotSemantics::Native.build_scope(statement))
    end

    def lineage(column, statement, schema, config = nil)
      config ||= LineageConfig.new(dialect: schema.dialect)
      LineageGraph.from_native(
        Upkeep::SqlglotSemantics::Native.lineage(column, statement, schema, config)
      )
    end
  end
end
