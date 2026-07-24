# frozen_string_literal: true

require "test_helper"

class SQLGlotAdapterCorpusTest < Minitest::Test
  SCHEMA = {
    "cards" => {
      "id" => "INTEGER",
      "project_id" => "INTEGER",
      "status" => "TEXT",
      "payload" => "JSON"
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

  CASES = {
    postgres_operator_and_function: {
      dialect: :postgres,
      sql: <<~SQL,
        SELECT cards.id
        FROM cards
        JOIN projects ON projects.id = cards.project_id
        WHERE cards.status ILIKE '%open%'
          AND cards.payload ->> 'state' = 'ready'
      SQL
      expected: {
        "cards" => %w[id payload project_id status],
        "projects" => %w[id]
      }
    },
    mysql_json_and_in: {
      dialect: :mysql,
      sql: <<~SQL,
        SELECT c.id
        FROM cards AS c
        JOIN projects AS p ON p.id = c.project_id
        WHERE JSON_EXTRACT(c.payload, '$.state') = '"ready"'
          AND c.status IN ('open', 'done')
      SQL
      expected: {
        "cards" => %w[id payload project_id status],
        "projects" => %w[id]
      }
    },
    sqlite_correlated_exists: {
      dialect: :sqlite,
      sql: <<~SQL,
        SELECT cards.id
        FROM cards
        WHERE EXISTS (
          SELECT 1 FROM efforts
          WHERE efforts.card_id = cards.id
            AND efforts.status = 'active'
        )
      SQL
      expected: {
        "cards" => %w[id],
        "efforts" => %w[card_id status]
      }
    },
    postgres_cte: {
      dialect: :postgres,
      sql: <<~SQL,
        WITH active_cards AS (
          SELECT id, project_id
          FROM cards
          WHERE status = 'active'
        )
        SELECT projects.id
        FROM projects
        JOIN active_cards ON active_cards.project_id = projects.id
      SQL
      expected: {
        "cards" => %w[id project_id status],
        "projects" => %w[id]
      }
    },
    mysql_union: {
      dialect: :mysql,
      sql: <<~SQL,
        SELECT id FROM cards WHERE status = 'active'
        UNION ALL
        SELECT card_id FROM efforts WHERE status = 'active'
      SQL
      expected: {
        "cards" => %w[id status],
        "efforts" => %w[card_id status]
      }
    }
  }.freeze

  def test_supported_adapter_corpus_has_no_dependency_false_negatives
    CASES.each do |name, example|
      result = analyze(example.fetch(:sql), dialect: example.fetch(:dialect))

      assert_equal example.fetch(:expected), result.table_columns, name
    end
  end

  def test_scope_validation_rejects_a_dependency_omission
    statement = Sqlglot.parse("SELECT cards.id FROM cards", dialect: :sqlite)
    schema = Sqlglot::MappingSchema.new(SCHEMA, dialect: :sqlite)
    qualified = Sqlglot.qualify_columns(statement, schema)
    wider_statement = Sqlglot.parse(
      "SELECT cards.id FROM cards JOIN projects ON projects.id = cards.project_id",
      dialect: :sqlite
    )
    wider_qualified = Sqlglot.qualify_columns(wider_statement, schema)

    error = assert_raises(Upkeep::SQLDependencyAnalysis::UnsupportedError) do
      Upkeep::SQLDependencyAnalysis.analyze(
        qualified,
        schema: SCHEMA,
        scope: Sqlglot.build_scope(wider_qualified)
      )
    end

    assert_includes error.message, "without a dependency"
  end

  private

  def analyze(sql, dialect:)
    statement = Sqlglot.parse(sql, dialect: dialect)
    mapping = Sqlglot::MappingSchema.new(SCHEMA, dialect: dialect)
    qualified = Sqlglot.qualify_columns(statement, mapping)
    dependency_statement =
      Upkeep::SQLDependencyAnalysis.preserve_wildcard_projections(
        statement,
        qualified
      )

    Upkeep::SQLDependencyAnalysis.analyze(
      dependency_statement,
      schema: SCHEMA,
      scope: Sqlglot.build_scope(dependency_statement)
    )
  end
end
