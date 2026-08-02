# frozen_string_literal: true

require "benchmark"
require_relative "../lib/upkeep"

sql = <<~SQL.gsub(/\s+/, " ").strip
  SELECT cards.id
  FROM cards
  JOIN projects ON projects.id = cards.project_id
  WHERE cards.status = 'open'
  ORDER BY projects.name
SQL
schema = {
  "cards" => {
    "id" => "INTEGER",
    "project_id" => "INTEGER",
    "status" => "TEXT"
  },
  "projects" => {
    "id" => "INTEGER",
    "name" => "TEXT"
  }
}.freeze
mapping = Sqlglot::MappingSchema.new(schema, dialect: :sqlite)
iterations = Integer(ENV.fetch("ITERATIONS", "10000"))

analyze = lambda do
  statement = Sqlglot.parse(sql, dialect: :sqlite)
  qualified = Sqlglot.qualify_columns(statement, mapping)
  dependency_statement =
    Upkeep::SQLDependencyAnalysis.preserve_wildcard_projections(
      statement,
      qualified
    )
  Upkeep::SQLDependencyAnalysis.analyze(
    dependency_statement,
    schema: schema,
    scope: Sqlglot.build_scope(dependency_statement)
  )
end

100.times { analyze.call }
elapsed = Benchmark.realtime { iterations.times { analyze.call } }

puts({
  iterations: iterations,
  total_seconds: elapsed.round(6),
  mean_microseconds: (elapsed * 1_000_000 / iterations).round(3)
}.inspect)
