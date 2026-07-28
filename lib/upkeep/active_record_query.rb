# frozen_string_literal: true

require "active_record"
require_relative "sqlglot"
require_relative "sql_dependency_analysis"

module Upkeep
  module ActiveRecordQuery
    class OpaqueRelationError < StandardError
      attr_reader :model_name, :table_name, :sql, :reasons

      def initialize(relation, reasons:)
        @model_name = relation.klass.name
        @table_name = relation.klass.table_name
        @sql = relation.to_sql
        @reasons = reasons

        super(build_message)
      rescue StandardError => error
        super("Upkeep could not analyze this Active Record relation: #{error.message}")
      end

      def suggestions
        [
          "Check that the relation emits valid SQL for the configured database adapter.",
          "Report unsupported SQL with the query, adapter, and SQLGlot version.",
          "Render this boundary outside Upkeep reactivity until the SQL is supported."
        ]
      end

      private

      def build_message
        <<~MESSAGE
          Upkeep cannot make this Active Record relation reactive because SQLGlot could not prove its dependencies.

          Relation:
            #{model_name} (#{table_name})

          SQL:
            #{sql}

          Why:
          #{reasons.map { |reason| "            - #{reason}" }.join("\n")}

          What to do:
          #{suggestions.map { |suggestion| "            - #{suggestion}" }.join("\n")}
        MESSAGE
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
      def appendable? = appendable
    end

    module_function

    def analyze(relation)
      sql = relation.to_sql
      dialect = dialect_for(relation.klass.connection)
      statement = SQLGlot.parse(sql, dialect: dialect)
      schema = Schema.for(relation.klass.connection, statement)
      mapping_schema = SQLGlot::MappingSchema.new(schema, dialect: dialect)
      qualified_statement = SQLGlot.qualify_columns(statement, mapping_schema)
      dependency_statement = SQLDependencyAnalysis.preserve_wildcard_projections(
        statement,
        qualified_statement
      )
      dependency = SQLDependencyAnalysis.analyze(
        dependency_statement,
        schema: schema,
        scope: SQLGlot.build_scope(dependency_statement)
      )

      Result.new(
        primary_table: relation.klass.table_name,
        table_columns: with_primary_key(
          dependency.table_columns,
          relation.klass.table_name,
          relation.klass.primary_key
        ),
        coverage: :columns,
        sql: sql,
        primary_key: relation.klass.primary_key,
        appendable: dependency.appendable?,
        limit_value: dependency.limit_value,
        predicates: dependency.predicates
      )
    rescue ActiveRecord::StatementInvalid,
      SQLGlot::Error,
      SQLDependencyAnalysis::UnsupportedError,
      KeyError => error
      raise OpaqueRelationError.new(
        relation,
        reasons: [
          "#{error.class}: #{error.message}",
          "dialect: #{safe_dialect(relation)}",
          "SQLGlot: #{SQLGlot.version}"
        ]
      )
    end

    def analyze_for_write(relation)
      analyze(relation)
    rescue OpaqueRelationError
      table_only_result(relation)
    end

    def dialect_for(connection)
      adapter = connection.adapter_name.to_s.downcase

      case adapter
      when /postgres/
        :postgres
      when /mysql|trilogy/
        :mysql
      when /sqlite/
        :sqlite
      when /sqlserver/
        :tsql
      when /oracle/
        :oracle
      else
        raise SQLDependencyAnalysis::UnsupportedError,
          "unsupported Active Record adapter: #{connection.adapter_name}"
      end
    end

    def with_primary_key(table_columns, primary_table, primary_key)
      columns = table_columns.transform_values(&:dup)
      columns[primary_table.to_s] ||= []
      columns[primary_table.to_s] << primary_key.to_s if primary_key
      columns.transform_values { |names| names.uniq.sort }.sort.to_h
    end
    private_class_method :with_primary_key

    def table_only_result(relation)
      primary_table = relation.klass.table_name
      primary_key = relation.klass.primary_key

      Result.new(
        primary_table: primary_table,
        table_columns: {
          primary_table => [primary_key].compact.map(&:to_s)
        },
        coverage: :tables,
        sql: relation.to_sql,
        primary_key: primary_key,
        appendable: false,
        limit_value: relation.limit_value,
        predicates: []
      )
    end
    private_class_method :table_only_result

    def safe_dialect(relation)
      dialect_for(relation.klass.connection)
    rescue StandardError
      relation.klass.connection.adapter_name
    end
    private_class_method :safe_dialect

    module Schema
      module_function

      def for(connection, statement)
        physical_tables(statement).each_with_object({}) do |table, schema|
          lookup_name = table.split(".").last
          columns = begin
            connection.schema_cache.columns(lookup_name).to_h do |column|
              [column.name, column.sql_type]
            end
          rescue ActiveRecord::StatementInvalid
            {}
          end
          schema[table] = columns.freeze unless columns.empty?
        end.freeze
      end

      def physical_tables(statement)
        collect_sources(statement, visible_ctes: Set.new).uniq.sort
      end

      def collect_sources(node, visible_ctes:)
        case node
        when Array
          node.flat_map { |child| collect_sources(child, visible_ctes: visible_ctes) }
        when Hash
          return collect_select(node.fetch("Select"), visible_ctes: visible_ctes) if node.key?("Select")
          return collect_table(node.fetch("Table"), visible_ctes: visible_ctes) if node.key?("Table")

          node.each_value.flat_map do |child|
            collect_sources(child, visible_ctes: visible_ctes)
          end
        else
          []
        end
      end
      private_class_method :collect_sources

      def collect_select(select, visible_ctes:)
        sources = []
        local_ctes = visible_ctes.dup

        Array(select["ctes"]).each do |cte|
          cte_scope = local_ctes.dup
          cte_scope << cte["name"] if cte["recursive"] && cte["name"]
          sources.concat(collect_sources(cte["query"], visible_ctes: cte_scope))
          local_ctes << cte["name"] if cte["name"]
        end

        select
          .reject { |key, _value| key == "ctes" }
          .each_value do |child|
            sources.concat(collect_sources(child, visible_ctes: local_ctes))
          end

        sources
      end
      private_class_method :collect_select

      def collect_table(table, visible_ctes:)
        name = [table["catalog"], table["schema"], table["name"]]
          .compact
          .reject(&:empty?)
          .join(".")
        unqualified = [table["catalog"], table["schema"]].all? do |part|
          part.nil? || part.empty?
        end

        return [] if unqualified && visible_ctes.include?(name)

        [name]
      end
      private_class_method :collect_table
    end
  end
end
