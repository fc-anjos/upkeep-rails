# frozen_string_literal: true

require "minitest/autorun"
require_relative "binding"

class SqlglotSemanticBindingTest < Minitest::Test
  SCHEMA = {
    "milestones" => %w[id name created_at],
    "efforts" => %w[id milestone_id status],
    "projects" => %w[id name],
    "cards" => %w[id project_id title]
  }.freeze

  def test_qualification_uses_schema_for_unqualified_columns
    result = analyze("SELECT id, title FROM cards WHERE project_id = 42", outputs: ["id"])

    assert_includes result.fetch("qualified_sql"), "cards.id"
    assert_includes result.fetch("qualified_sql"), "cards.title"
    assert_includes result.fetch("qualified_sql"), "cards.project_id"
  end

  def test_scope_exposes_correlated_subquery_semantics
    result = analyze(compact_sql(<<~SQL), outputs: ["id"])
      SELECT milestones.id
      FROM milestones
      WHERE EXISTS (
        SELECT 1
        FROM efforts
        WHERE efforts.milestone_id = milestones.id
          AND efforts.status = 'active'
      )
    SQL

    inner = all_scopes(result.fetch("scope")).find { |scope| scope.fetch("scope_type") == "Subquery" }
    refute_nil inner
    assert inner.fetch("correlated")
    assert_includes inner.fetch("external_columns"), {"table" => "milestones", "name" => "id"}
    assert_includes inner.fetch("columns"), {"table" => "efforts", "name" => "milestone_id"}
    assert_includes inner.fetch("columns"), {"table" => "efforts", "name" => "status"}
  end

  def test_scope_exposes_cte_child_but_current_upstream_misclassifies_its_root_reference
    result = analyze(compact_sql(<<~SQL), outputs: ["id"])
      WITH active_cards AS (
        SELECT id, project_id FROM cards WHERE title IS NOT NULL
      )
      SELECT projects.id
      FROM projects
      JOIN active_cards ON active_cards.project_id = projects.id
    SQL

    root = result.fetch("scope")
    # v0.10.12 reports the CTE reference as a table source.
    assert_equal "table", root.fetch("sources").fetch("active_cards").fetch("kind")
    cte = all_scopes(root).find { |scope| scope.fetch("scope_type") == "Cte" }
    assert_equal "cards", cte.fetch("sources").fetch("cards").fetch("physical_name")
  end

  def test_output_lineage_is_not_filter_dependency_lineage
    result = analyze(compact_sql(<<~SQL), outputs: ["id"])
      SELECT milestones.id
      FROM milestones
      WHERE EXISTS (
        SELECT 1 FROM efforts
        WHERE efforts.milestone_id = milestones.id
      )
    SQL

    lineage_json = result.fetch("lineage").fetch("id").to_s
    assert_includes lineage_json, "milestones"
    refute_includes lineage_json, "efforts"

    scope_json = result.fetch("scope").to_s
    assert_includes scope_json, "efforts"
  end

  def test_parse_errors_cross_ffi_as_structured_errors
    error = assert_raises(ArgumentError) { analyze("SELECT FROM", outputs: []) }

    assert_match(/parse|Expected|Unexpected/i, error.message)
  end

  private

  def analyze(sql, outputs:)
    SqlglotSemanticBinding.analyze(sql, dialect: :sqlite, schema: SCHEMA, outputs: outputs)
  end

  def all_scopes(scope)
    [scope] + scope.fetch("children").flat_map { |child| all_scopes(child) }
  end

  def compact_sql(sql)
    sql.gsub(/\s+/, " ").strip
  end
end
