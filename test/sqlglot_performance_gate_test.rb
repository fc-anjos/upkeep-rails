# frozen_string_literal: true

require "benchmark"
require "test_helper"

class SQLGlotPerformanceGateTest < Minitest::Test
  SCHEMA = {
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

  SQL = <<~SQL.gsub(/\s+/, " ").strip
    SELECT cards.id
    FROM cards
    JOIN projects ON projects.id = cards.project_id
    WHERE cards.status = 'open'
    ORDER BY projects.name
  SQL

  def test_warm_semantic_analysis_stays_inside_the_ci_budget
    mapping = Upkeep::SQLGlot::MappingSchema.new(SCHEMA, dialect: :sqlite)
    analyze = lambda do
      statement = Upkeep::SQLGlot.parse(SQL, dialect: :sqlite)
      qualified = Upkeep::SQLGlot.qualify_columns(statement, mapping)
      dependency_statement =
        Upkeep::SQLDependencyAnalysis.preserve_wildcard_projections(
          statement,
          qualified
        )
      Upkeep::SQLDependencyAnalysis.analyze(
        dependency_statement,
        schema: SCHEMA,
        scope: Upkeep::SQLGlot.build_scope(dependency_statement)
      )
    end

    20.times { analyze.call }
    iterations = 200
    elapsed = Benchmark.realtime { iterations.times { analyze.call } }
    mean_seconds = elapsed / iterations
    budget_seconds = Float(ENV.fetch("UPKEEP_SQL_ANALYSIS_BUDGET_SECONDS", "0.002"))

    assert_operator mean_seconds, :<, budget_seconds,
      "warm SQL analysis mean #{(mean_seconds * 1_000_000).round(1)}µs " \
      "exceeded #{(budget_seconds * 1_000_000).round(1)}µs"
  end
end
