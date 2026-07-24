# frozen_string_literal: true

require "sqlglot"
require "set"

# Minimal table-only extraction suitable for conservative invalidation.
module SqlglotDependencyExtractor
  module_function

  def tables(sql, dialect:)
    ast = Sqlglot.parse(sql, dialect: dialect)
    collect_sources(ast, visible_ctes: Set.new).uniq.sort
  end

  def collect_sources(node, visible_ctes:)
    case node
    when Array
      node.flat_map { |child| collect_sources(child, visible_ctes: visible_ctes) }
    when Hash
      return collect_select(node.fetch("Select"), visible_ctes: visible_ctes) if node.key?("Select")
      return collect_table(node.fetch("Table"), visible_ctes: visible_ctes) if node.key?("Table")

      node.each_value.flat_map { |child| collect_sources(child, visible_ctes: visible_ctes) }
    else
      []
    end
  end
  private_class_method :collect_sources

  def collect_select(select, visible_ctes:)
    sources = []
    local_ctes = visible_ctes.dup

    Array(select["ctes"]).each do |cte|
      cte_name = cte["name"]
      cte_scope = local_ctes.dup
      cte_scope << cte_name if cte["recursive"] && cte_name
      sources.concat(collect_sources(cte["query"], visible_ctes: cte_scope))
      local_ctes << cte_name if cte_name
    end

    select
      .reject { |key, _value| key == "ctes" }
      .each_value { |child| sources.concat(collect_sources(child, visible_ctes: local_ctes)) }

    sources
  end
  private_class_method :collect_select

  def collect_table(table, visible_ctes:)
    name = qualified_table_name(table)
    return [] unless name
    return [] if unqualified_table?(table) && visible_ctes.include?(name)

    [name]
  end
  private_class_method :collect_table

  def unqualified_table?(table)
    [table["catalog"], table["schema"]].all? { |part| part.nil? || part.empty? }
  end
  private_class_method :unqualified_table?

  def qualified_table_name(table)
    parts = [table["catalog"], table["schema"], table["name"]]
      .compact
      .reject(&:empty?)

    parts.join(".") unless parts.empty?
  end
  private_class_method :qualified_table_name
end
