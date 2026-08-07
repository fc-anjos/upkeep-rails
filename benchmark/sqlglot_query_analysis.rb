# frozen_string_literal: true

# Parse-cost harness for the SQLGlot binding: the full analysis pass a
# registered query shape would pay once (parse, schema-qualify, scope).
# Run: ruby -Ilib benchmark/sqlglot_query_analysis.rb [ITERATIONS=10000]
require "benchmark"
require "upkeep/sqlglot"

sql = <<~SQL.gsub(/\s+/, " ").strip
  SELECT cards.id
  FROM cards
  JOIN projects ON projects.id = cards.project_id
  WHERE cards.status = 'open'
  ORDER BY projects.name
SQL
schema = Upkeep::SQLGlot::MappingSchema.new(
  {
    "cards" => {
      "id" => "INTEGER",
      "project_id" => "INTEGER",
      "status" => "TEXT"
    },
    "projects" => {
      "id" => "INTEGER",
      "name" => "TEXT"
    }
  },
  dialect: :sqlite
)
iterations = Integer(ENV.fetch("ITERATIONS", "10000"))

analyze = lambda do
  statement = Upkeep::SQLGlot.parse(sql, dialect: :sqlite)
  qualified = Upkeep::SQLGlot.qualify_columns(statement, schema)
  Upkeep::SQLGlot.build_scope(qualified)
end

100.times { analyze.call }
elapsed = Benchmark.realtime { iterations.times { analyze.call } }

puts({
  iterations: iterations,
  total_seconds: elapsed.round(6),
  mean_microseconds: (elapsed * 1_000_000 / iterations).round(3)
}.inspect)
