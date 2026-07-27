# frozen_string_literal: true

require "set"
require "sqlglot"

module SqlglotActiveRecordQuery
  Analysis = Data.define(
    :primary_table,
    :table_columns,
    :predicates,
    :equality_edges,
    :sql,
    :limit_value,
    :appendable,
    :warnings
  ) do
    def tables = table_columns.keys.sort
    def appendable? = appendable
  end

  module_function

  def analyze(relation, dialect: :sqlite)
    Analyzer.new(relation, dialect: dialect).analyze
  end

  def schema_columns_for(connection)
    @schema_columns ||= {}
    @schema_columns[connection.object_id] ||= connection.tables.to_h do |table|
      [table, connection.columns(table).map(&:name).to_set.freeze]
    end.freeze
  end

  class Analyzer
    def initialize(relation, dialect:)
      @relation = relation
      @dialect = dialect
      @primary_table = relation.klass.table_name
      @primary_key = relation.klass.primary_key
      @columns_by_table = SqlglotActiveRecordQuery.schema_columns_for(relation.klass.connection)
      @table_columns = Hash.new { |hash, table| hash[table] = Set.new }
      @predicates = []
      @equality_edges = Set.new
      @warnings = []
    end

    def analyze
      sql = @relation.to_sql
      ast = Sqlglot.parse(sql, dialect: @dialect)
      root = ast.fetch("Select")
      process_select(root, outer_sources: {}, visible_ctes: {})
      record_column(@primary_table, @primary_key) if @primary_key

      Analysis.new(
        primary_table: @primary_table,
        table_columns: @table_columns.transform_values { |columns| columns.to_a.sort }.sort.to_h,
        predicates: @predicates.sort_by { |predicate| predicate.values_at(:group, :table, :column, :operator).map(&:to_s) },
        equality_edges: @equality_edges.to_a.sort,
        sql: sql,
        limit_value: literal_value(root["limit"]),
        appendable: appendable?(root),
        warnings: @warnings.uniq
      )
    rescue StandardError => error
      raise ArgumentError, "SQLGlot could not analyze #{@relation.klass.name}: #{error.class}: #{error.message}"
    end

    private

    Source = Data.define(:physical_tables)

    def process_select(select, outer_sources:, visible_ctes:)
      ctes = visible_ctes.dup
      Array(select["ctes"]).each do |cte|
        before = @table_columns.keys.to_set
        process_query(cte["query"], outer_sources: outer_sources, visible_ctes: ctes)
        discovered = @table_columns.keys.to_set - before
        # A CTE can reuse a table discovered elsewhere.
        discovered.merge(physical_tables_in(cte["query"], ctes))
        ctes[cte["name"]] = Source.new(discovered.to_a)
      end

      local_sources = source_map(select, ctes)
      visible_sources = outer_sources.merge(local_sources)

      walk_select_body(select, sources: visible_sources, visible_ctes: ctes)
    end

    def process_query(query, outer_sources:, visible_ctes:)
      if query.is_a?(Hash) && query.key?("Select")
        process_select(query.fetch("Select"), outer_sources: outer_sources, visible_ctes: visible_ctes)
      else
        walk(query, sources: outer_sources, visible_ctes: visible_ctes)
      end
    end

    def source_map(select, ctes)
      nodes = []
      nodes << select.dig("from", "source")
      nodes.concat(Array(select["joins"]).map { |join| join["table"] })

      nodes.compact.each_with_object({}) do |node, sources|
        table = node["Table"] if node.is_a?(Hash)
        if table
          name = table["name"]
          source = ctes[name] || Source.new([qualified_table_name(table)])
          sources[name] = source
          sources[table["alias"]] = source if table["alias"]
          source.physical_tables.each { |physical| @table_columns[physical] }
        elsif node.is_a?(Hash) && node.key?("Subquery")
          derived = node.fetch("Subquery")
          before = @table_columns.keys.to_set
          process_query(derived["query"], outer_sources: sources, visible_ctes: ctes)
          physical = (@table_columns.keys.to_set - before).to_a
          physical = @table_columns.keys if physical.empty?
          sources[derived["alias"]] = Source.new(physical) if derived["alias"]
        else
          @warnings << "source shape not resolved: #{node&.keys&.first || node.class}"
        end
      end
    end

    def walk_select_body(select, sources:, visible_ctes:)
      select.each do |key, value|
        next if %w[ctes from].include?(key)

        if key == "joins"
          Array(value).each do |join|
            walk(join.reject { |join_key, _| join_key == "table" }, sources: sources, visible_ctes: visible_ctes)
            record_predicates(join["on"], sources)
          end
        else
          walk(value, sources: sources, visible_ctes: visible_ctes)
        end
      end

      record_predicates(select["where_clause"], sources)
      record_predicates(select["having"], sources)
    end

    def walk(node, sources:, visible_ctes:)
      case node
      when Array
        node.each { |child| walk(child, sources: sources, visible_ctes: visible_ctes) }
      when Hash
        if node.key?("Select")
          process_select(node.fetch("Select"), outer_sources: sources, visible_ctes: visible_ctes)
        elsif node.key?("Column")
          record_resolved_column(node.fetch("Column"), sources)
        else
          node.each_value { |child| walk(child, sources: sources, visible_ctes: visible_ctes) }
        end
      end
    end

    def record_resolved_column(column, sources)
      name = column["name"]
      qualifier = column["table"]
      candidates =
        if qualifier && sources[qualifier]
          sources.fetch(qualifier).physical_tables
        elsif qualifier
          [qualifier]
        else
          local = sources.values.uniq.flat_map(&:physical_tables).uniq
          matches = local.select { |table| @columns_by_table.fetch(table, Set.new).include?(name) }
          matches.empty? ? local : matches
        end

      if candidates.one?
        record_column(candidates.first, name)
      elsif candidates.empty?
        @warnings << "column #{[qualifier, name].compact.join('.')} has no physical source"
      else
        candidates.each { |table| record_column(table, name) }
        @warnings << "column #{name} is ambiguous; conservatively attached to #{candidates.sort.join(', ')}"
      end
    end

    def record_predicates(expression, sources)
      dnf(expression).each_with_index do |group, group_index|
        group.each do |term|
          predicate = simple_predicate(term, sources)
          next unless predicate

          predicate[:group] = group_index if dnf(expression).length > 1
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
        column = extract_column(list["expr"])
        values = Array(list["list"]).map { |value| literal_value(value) }
        return build_predicate(column, list["negated"] ? "not_in" : "in", values, sources)
      elsif node.is_a?(Hash) && node.key?("IsNull")
        null = node.fetch("IsNull")
        return build_predicate(extract_column(null["expr"]), null["negated"] ? "not_eq" : "eq", [nil], sources)
      end
    end

    def binary_predicate(binary, sources)
      left = extract_column(binary["left"])
      right = extract_column(binary["right"])
      if left && right
        endpoints = [resolved_endpoint(left, sources), resolved_endpoint(right, sources)]
        @equality_edges << endpoints.sort.join("=") if endpoints.all?
        return
      end

      column, value_node = left ? [left, binary["right"]] : [right, binary["left"]]
      return unless column

      value = literal_value(value_node)
      return if value == :unknown

      build_predicate(column, binary["op"] == "Eq" ? "eq" : "not_eq", [value], sources)
    end

    def build_predicate(column, operator, values, sources)
      return unless column

      table = resolved_tables(column, sources).one? && resolved_tables(column, sources).first
      return unless table

      { table: table, column: column["name"], operator: operator, values: values }
    end

    def extract_column(node)
      node["Column"] if node.is_a?(Hash) && node.key?("Column")
    end

    def resolved_endpoint(column, sources)
      tables = resolved_tables(column, sources)
      "#{tables.first}.#{column['name']}" if tables.one?
    end

    def resolved_tables(column, sources)
      qualifier = column["table"]
      return sources.fetch(qualifier).physical_tables if qualifier && sources[qualifier]
      return [qualifier] if qualifier

      local = sources.values.uniq.flat_map(&:physical_tables).uniq
      matches = local.select { |table| @columns_by_table.fetch(table, Set.new).include?(column["name"]) }
      matches.empty? ? local : matches
    end

    def literal_value(node)
      return nil if node.nil?
      return :unknown unless node.is_a?(Hash)
      return node["StringLiteral"] if node.key?("StringLiteral")
      return integer_or_float(node["Number"]) if node.key?("Number")
      return node["Boolean"] if node.key?("Boolean")
      return nil if node.key?("Null")
      return literal_value(node["UnaryOp"]["expr"]) * -1 if node.key?("UnaryOp") && node["UnaryOp"]["op"] == "Minus"

      :unknown
    end

    def integer_or_float(value)
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
          visible_ctes[table["name"]]&.physical_tables || [qualified_table_name(table)]
        else
          node.values.flat_map { |child| physical_tables_in(child, visible_ctes) }
        end
      else
        []
      end
      values.to_a.compact.flatten.uniq
    end

    def qualified_table_name(table)
      [table["catalog"], table["schema"], table["name"]].compact.reject(&:empty?).join(".")
    end

    def record_column(table, column)
      @table_columns[table] << column.to_s
    end

  end
end
