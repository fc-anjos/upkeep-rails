# frozen_string_literal: true

require "test_helper"

class SQLDependencyAnalysisTest < Minitest::Test
  SCHEMA = {
    "cards" => {
      "id" => "INTEGER",
      "project_id" => "INTEGER",
      "status" => "TEXT"
    },
    "efforts" => {
      "id" => "INTEGER",
      "card_id" => "INTEGER",
      "status" => "TEXT"
    },
    "projects" => {
      "id" => "INTEGER",
      "name" => "TEXT"
    }
  }.freeze

  def test_correlated_exists_records_inner_and_external_dependencies
    result = analyze(<<~SQL)
      SELECT cards.id
      FROM cards
      WHERE EXISTS (
        SELECT 1
        FROM efforts
        WHERE efforts.card_id = cards.id
          AND efforts.status = 'active'
      )
    SQL

    assert_equal({
      "cards" => ["id"],
      "efforts" => %w[card_id status]
    }, result.table_columns)
    assert_equal ["cards.id=efforts.card_id"], result.equality_edges
    assert_includes result.predicates, {
      table: "efforts",
      column: "status",
      operator: "eq",
      values: ["active"]
    }
  end

  def test_cte_name_is_logical_and_physical_sources_are_preserved
    result = analyze(<<~SQL)
      WITH active_cards AS (
        SELECT id, project_id
        FROM cards
        WHERE status = 'active'
      )
      SELECT projects.id
      FROM projects
      JOIN active_cards ON active_cards.project_id = projects.id
    SQL

    assert_equal %w[cards projects], result.tables
    refute_includes result.tables, "active_cards"
    assert_equal %w[id project_id status], result.table_columns.fetch("cards")
    assert_equal ["cards.project_id=projects.id"], result.equality_edges
  end

  def test_union_collects_dependencies_from_both_branches
    result = analyze(<<~SQL)
      SELECT id FROM cards WHERE status = 'active'
      UNION
      SELECT card_id FROM efforts WHERE status = 'active'
    SQL

    assert_equal %w[cards efforts], result.tables
    assert_equal %w[id status], result.table_columns.fetch("cards")
    assert_equal %w[card_id status], result.table_columns.fetch("efforts")
    refute result.appendable?
  end

  def test_unknown_physical_table_fails_closed
    error = assert_raises(Upkeep::SQLDependencyAnalysis::UnsupportedError) do
      analyze("SELECT cards.id FROM cards JOIN missing ON missing.card_id = cards.id")
    end

    assert_includes error.message, "missing"
    assert_includes error.message, "not present in the schema"
  end

  private

  def analyze(sql)
    statement = Sqlglot.parse(sql, dialect: :sqlite)
    Upkeep::SQLDependencyAnalysis.analyze(statement, schema: SCHEMA)
  end
end
