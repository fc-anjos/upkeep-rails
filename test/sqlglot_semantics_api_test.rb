# frozen_string_literal: true

require "minitest/autorun"
require "upkeep/sqlglot"

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

  def test_wrapper_stays_inside_the_upkeep_namespace
    refute Object.const_defined?(:Sqlglot)
  end

  def test_mapping_schema_preserves_ordered_table_paths_and_types
    schema = mapping_schema

    assert_equal :sqlite, schema.dialect.to_sym
    assert_equal(
      {
        path: ["cards"],
        columns: [
          {name: "id", data_type: "INTEGER"},
          {name: "project_id", data_type: "INTEGER"},
          {name: "status", data_type: "TEXT"},
          {name: "title", data_type: "TEXT"}
        ]
      },
      schema.to_native.fetch(:tables).fetch(0)
    )
    assert_equal(
      %w[UNKNOWN UNKNOWN UNKNOWN UNKNOWN],
      schema.to_dependency_native.fetch(:tables).fetch(0).fetch(:columns)
        .map { |column| column.fetch(:data_type) }
    )
  end

  def test_parse_generate_and_transpile_use_the_bundled_rust_library
    statement = parse("SELECT id FROM cards")

    assert_equal "0.10.26", Upkeep::SQLGlot.version
    assert_includes Upkeep::SQLGlot.generate(statement, dialect: :sqlite),
      "SELECT id FROM cards"
    assert_includes(
      Upkeep::SQLGlot.transpile(
        "SELECT * FROM cards LIMIT 1",
        from: :mysql,
        to: :tsql
      ),
      "TOP 1"
    )
  end

  def test_postgres_json_path_operators_round_trip
    sql = "SELECT data #> '{commit,author}', data #>> '{commit,author,date}' FROM commits"
    statement = Upkeep::SQLGlot.parse(sql, dialect: :postgres)
    generated = Upkeep::SQLGlot.generate(statement, dialect: :postgres)

    assert_includes generated, "data #> '{commit,author}'"
    assert_includes generated, "data #>> '{commit,author,date}'"
  end

  def test_qualify_columns_returns_the_sqlglot_statement_shape
    statement = parse("SELECT id, title FROM cards WHERE project_id = 42")
    qualified = Upkeep::SQLGlot.qualify_columns(statement, mapping_schema)

    sql = Upkeep::SQLGlot.generate(qualified, dialect: :sqlite)
    assert_includes sql, "cards.id"
    assert_includes sql, "cards.title"
    assert_includes sql, "cards.project_id"
  end

  def test_dependency_analysis_does_not_parse_database_types
    schema = Upkeep::SQLGlot::MappingSchema.new(
      {
        "events" => {
          "id" => "BIGINT",
          "state" => "app.custom_type",
          "measurements" => "NUMERIC(38, 9)[]"
        }
      },
      dialect: :postgres
    )
    statement = Upkeep::SQLGlot.parse(
      "SELECT id, state, measurements FROM events",
      dialect: :postgres
    )

    qualified = Upkeep::SQLGlot.qualify_columns(statement, schema)
    sql = Upkeep::SQLGlot.generate(qualified, dialect: :postgres)

    assert_includes sql, "events.id"
    assert_includes sql, "events.state"
    assert_includes sql, "events.measurements"

    lineage = Upkeep::SQLGlot.lineage("state", qualified, schema)
    assert_includes lineage.source_tables, "events"
    assert_equal(
      ["BIGINT", "app.custom_type", "NUMERIC(38, 9)[]"],
      schema.to_native.fetch(:tables).fetch(0).fetch(:columns)
        .map { |column| column.fetch(:data_type) }
    )
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
    scope = Upkeep::SQLGlot.build_scope(statement)
    inner = scope.subquery_scopes.fetch(0)

    assert_equal :root, scope.scope_type
    assert_equal :subquery, inner.scope_type
    assert inner.is_correlated
    assert_includes inner.external_columns,
      Upkeep::SQLGlot::ColumnRef.new(table: "cards", name: "id")
    assert_equal ["efforts"], inner.sources.keys
    assert_equal [inner], scope.child_scopes
  end

  def test_build_scope_preserves_cte_sources_as_scopes
    statement = parse(<<~SQL)
      WITH active_cards AS (
        SELECT id, project_id FROM cards WHERE status = 'active'
      )
      SELECT projects.id
      FROM projects
      JOIN active_cards ON active_cards.project_id = projects.id
    SQL
    qualified = Upkeep::SQLGlot.qualify_columns(statement, mapping_schema)
    scope = Upkeep::SQLGlot.build_scope(qualified)

    assert_equal :scope, scope.sources.fetch("active_cards").kind
    assert_equal :cte, scope.cte_scopes.fetch(0).scope_type
    assert_equal ["cards"], scope.cte_scopes.fetch(0).sources.keys
  end

  def test_lineage_matches_the_rust_graph_shape
    statement = parse("SELECT cards.id AS card_id FROM cards")
    graph = Upkeep::SQLGlot.lineage("card_id", statement, mapping_schema)

    assert_equal :sqlite, graph.dialect
    assert_equal "card_id", graph.node.name
    assert_includes graph.source_tables, "cards"
    assert graph.walk.any?
  end

  def test_native_errors_cross_the_boundary_with_diagnostics
    invalid = {"Select" => {"not" => "a statement"}}

    error = assert_raises(Upkeep::SQLGlot::SemanticError) do
      Upkeep::SQLGlot.build_scope(invalid)
    end

    assert_equal "Failed to build SQLGlot scope", error.message
  end

  private

  def mapping_schema
    Upkeep::SQLGlot::MappingSchema.new(SCHEMA, dialect: :sqlite)
  end

  def parse(sql)
    Upkeep::SQLGlot.parse(sql.gsub(/\s+/, " ").strip, dialect: :sqlite)
  end
end
