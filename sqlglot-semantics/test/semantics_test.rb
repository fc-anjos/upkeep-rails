# frozen_string_literal: true

require "minitest/autorun"
require "sqlglot/semantics"

class SqlglotSemanticsTest < Minitest::Test
  SCHEMA = {
    "cards" => {
      "id" => "INTEGER",
      "project_id" => "INTEGER",
      "status" => "TEXT",
      "title" => "TEXT"
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

  def test_mapping_schema_matches_established_schema_operations
    schema = mapping_schema

    assert_equal [
      ["", "", "cards"],
      ["", "", "efforts"],
      ["", "", "projects"]
    ], schema.table_names
    assert_equal %w[id project_id status title], schema.column_names("cards")
    assert_equal "INTEGER", schema.get_column_type("cards", "id")
    assert schema.has_column("cards", "title")
    refute schema.has_column("cards", "missing")

    schema.add_table(%w[public labels], {"id" => "BIGINT"})
    assert_equal ["id"], schema.column_names("public.labels")
    assert_raises(ArgumentError) do
      schema.add_table("public.labels", {"id" => "BIGINT"})
    end
    schema.replace_table("public.labels", {"name" => "TEXT"})
    assert_equal ["name"], schema.column_names("public.labels")
    assert schema.remove_table("public.labels")
  end

  def test_qualify_columns_returns_the_sqlglot_statement_shape
    statement = parse("SELECT id, title FROM cards WHERE project_id = 42")
    qualified = Sqlglot.qualify_columns(statement, mapping_schema)

    sql = Sqlglot.generate(qualified, dialect: :sqlite)
    assert_includes sql, "cards.id"
    assert_includes sql, "cards.title"
    assert_includes sql, "cards.project_id"
  end

  def test_build_scope_preserves_rust_fields_and_correlation
    statement = parse(<<~SQL)
      SELECT cards.id
      FROM cards
      WHERE EXISTS (
        SELECT 1
        FROM efforts
        WHERE efforts.card_id = cards.id
          AND efforts.status = 'active'
      )
    SQL
    scope = Sqlglot.build_scope(statement)
    inner = scope.subquery_scopes.fetch(0)

    assert_equal :Root, scope.scope_type
    assert_equal :Subquery, inner.scope_type
    assert inner.is_correlated
    assert_includes inner.external_columns,
      Sqlglot::ColumnRef.new(table: "cards", name: "id")
    assert_equal ["efforts"], inner.sources.keys
    assert_equal [inner], scope.child_scopes
  end

  def test_build_scope_exposes_cte_scope_even_with_upstream_01012_source_bug
    statement = parse(<<~SQL)
      WITH active_cards AS (
        SELECT id, project_id FROM cards WHERE status = 'active'
      )
      SELECT projects.id
      FROM projects
      JOIN active_cards ON active_cards.project_id = projects.id
    SQL
    qualified = Sqlglot.qualify_columns(statement, mapping_schema)
    scope = Sqlglot.build_scope(qualified)

    assert_equal :table, scope.sources.fetch("active_cards").kind
    assert_equal "active_cards",
      scope.sources.fetch("active_cards").table.qualified_name
    assert_equal :Cte, scope.cte_scopes.fetch(0).scope_type
    assert_equal ["cards"], scope.cte_scopes.fetch(0).sources.keys
  end

  def test_lineage_matches_the_rust_graph_shape
    statement = parse("SELECT cards.id AS card_id FROM cards")
    graph = Sqlglot.lineage("card_id", statement, mapping_schema)

    assert_equal :sqlite, graph.dialect
    assert_equal "card_id", graph.node.name
    assert_includes graph.source_tables, "cards"
    assert graph.walk.any?
  end

  def test_native_errors_cross_the_boundary_with_diagnostics
    invalid = {"Select" => {"not" => "a statement"}}

    error = assert_raises(Sqlglot::Semantics::Error) do
      Sqlglot.build_scope(invalid)
    end

    assert_match(/statement JSON|missing field|unknown field/i, error.message)
  end

  private

  def mapping_schema
    Sqlglot::MappingSchema.new(SCHEMA, dialect: :sqlite)
  end

  def parse(sql)
    Sqlglot.parse(sql.gsub(/\s+/, " ").strip, dialect: :sqlite)
  end
end
