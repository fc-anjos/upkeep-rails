# frozen_string_literal: true

require "minitest/autorun"
require "sqlglot"
require_relative "sqlglot_dependency_extractor"

# PostgreSQL emitted-SQL equivalents of the query shapes rewritten in
# fetchly/Pulse#1802. These deliberately test the SQLGlot fallback rather than
# the replacement Arel, so values that Active Record would bind are inlined.
class Pulse1802EdgeCasesTest < Minitest::Test
  Case = Data.define(:name, :pr_source, :sql, :tables)

  CASES = [
    Case.new(
      name: "nested date range predicate",
      pr_source: "Assignment.current",
      sql: <<~SQL,
        SELECT "assignments".*
        FROM "assignments"
        WHERE "assignments"."start_date" <= DATE '2026-07-24'
          AND (
            "assignments"."end_date" >= DATE '2026-07-24'
            OR "assignments"."end_date" IS NULL
          )
      SQL
      tables: ["assignments"]
    ),
    Case.new(
      name: "overlapping ranges with two disjunctions",
      pr_source: "Project::Staffable#requirements_change_summary",
      sql: <<~SQL,
        SELECT "project_team_requirements".*
        FROM "project_team_requirements"
        WHERE "project_team_requirements"."position_id" = 17
          AND (
            (
              "project_team_requirements"."start_date" <= TIMESTAMP '2026-07-26 23:59:59'
              AND (
                "project_team_requirements"."end_date" IS NULL
                OR "project_team_requirements"."end_date" > TIMESTAMP '2026-07-26 23:59:59'
              )
            )
            OR (
              "project_team_requirements"."end_date" >= TIMESTAMP '2026-07-20 00:00:00'
              AND "project_team_requirements"."end_date" <= TIMESTAMP '2026-07-26 23:59:59'
            )
          )
      SQL
      tables: ["project_team_requirements"]
    ),
    Case.new(
      name: "self-correlated exists with alias",
      pr_source: "Effort::Filterable.by_blockers",
      sql: <<~SQL,
        SELECT "efforts".*
        FROM "efforts"
        WHERE "efforts"."is_blocker" = TRUE
          AND EXISTS (
            SELECT 1
            FROM "efforts" AS "child_efforts"
            WHERE "child_efforts"."parent_id" = "efforts"."id"
              AND "child_efforts"."discarded_at" IS NULL
          )
      SQL
      tables: ["efforts"]
    ),
    Case.new(
      name: "jsonb containment operator and cast",
      pr_source: "AuditedHelper#last_estimate_audit",
      sql: <<~SQL,
        SELECT "audits".*
        FROM "audits"
        WHERE "audits"."auditable_type" = 'Effort'
          AND "audits"."auditable_id" = 42
          AND "audits"."action" = 'update'
          AND "audits"."audited_changes" @> '{"estimated_time_seconds":[]}'::jsonb
        ORDER BY "audits"."created_at" DESC
        LIMIT 1
      SQL
      tables: ["audits"]
    ),
    Case.new(
      name: "json extraction operator",
      pr_source: "Effort::Auditable#date_added_to_milestone",
      sql: <<~SQL,
        SELECT "audits".*
        FROM "audits"
        WHERE "audits"."auditable_type" = 'Effort'
          AND "audits"."auditable_id" = 42
          AND "audits"."action" IN ('create', 'update')
          AND ("audits"."audited_changes" -> 'milestone_id') IS NOT NULL
      SQL
      tables: ["audits"]
    ),
    Case.new(
      name: "correlated aggregate scalar subquery",
      pr_source: "Effort::Filterable.over_budget",
      sql: <<~SQL,
        SELECT "efforts".*
        FROM "efforts"
        WHERE "efforts"."estimated_time_seconds" > 0
          AND "efforts"."estimated_time_seconds" < (
            SELECT COALESCE(SUM("time_logs"."duration"), 0)
            FROM "time_logs"
            WHERE "time_logs"."time_trackable_type" = 'Effort'
              AND "time_logs"."time_trackable_id" = "efforts"."id"
          )
      SQL
      tables: %w[efforts time_logs]
    ),
    Case.new(
      name: "case expression with repeated correlated exists",
      pr_source: "Milestone.status_case_sql",
      sql: <<~SQL,
        SELECT CASE
          WHEN NOT EXISTS (
            SELECT 1 FROM "efforts"
            WHERE "efforts"."milestone_id" = "milestones"."id"
              AND "efforts"."discarded_at" IS NULL
              AND ("efforts"."effort_type" IS NULL OR "efforts"."effort_type" <> 2)
          ) THEN 'planned'
          WHEN "milestones"."due_date" < DATE '2026-07-24'
            AND EXISTS (
              SELECT 1 FROM "efforts"
              WHERE "efforts"."milestone_id" = "milestones"."id"
                AND "efforts"."discarded_at" IS NULL
                AND "efforts"."current_state" <> 'done'
            ) THEN 'overdue'
          WHEN EXISTS (
            SELECT 1 FROM "efforts"
            WHERE "efforts"."milestone_id" = "milestones"."id"
              AND "efforts"."current_state" IN ('in_progress', 'qa')
          ) THEN 'active'
          ELSE 'planned'
        END AS "derived_status"
        FROM "milestones"
      SQL
      tables: %w[efforts milestones]
    ),
    Case.new(
      name: "aggregate over case with join",
      pr_source: "Project::Staffable#active_requirements_count",
      sql: <<~SQL,
        SELECT COALESCE(
          SUM(
            CASE
              WHEN "project_team_requirements"."role" = 1
                THEN "project_team_requirements"."quantity" / 2.0
              ELSE "project_team_requirements"."quantity"
            END
          ),
          0
        )
        FROM "project_team_requirements"
        INNER JOIN "positions"
          ON "positions"."id" = "project_team_requirements"."position_id"
          AND "positions"."discarded_at" IS NULL
        WHERE "positions"."name" IN ('Developer', 'Senior Developer')
      SQL
      tables: %w[positions project_team_requirements]
    ),
    Case.new(
      name: "two-column pluck across outer join",
      pr_source: "User::Assignable#assignment_project_ids",
      sql: <<~SQL,
        SELECT "assignments"."project_id", "teams"."project_id"
        FROM "assignments"
        LEFT OUTER JOIN "teams"
          ON "teams"."id" = "assignments"."team_id"
        WHERE "assignments"."user_id" = 9
      SQL
      tables: %w[assignments teams]
    ),
    Case.new(
      name: "pg_search tsearch plus trigram rank without pg_trgm predicate",
      pr_source: "ProjectsController#index materialized pg_search relation",
      sql: <<~SQL,
        SELECT "projects".*,
          (
            ts_rank(
              to_tsvector('simple', unaccent(COALESCE("projects"."name"::text, ''))),
              to_tsquery('simple', '''upkeep'':*')
            )
            + (
              0.5 * word_similarity(
                'upkeep',
                unaccent(COALESCE("projects"."name"::text, ''))
              )
            )
          ) AS "pg_search_rank"
        FROM "projects"
        WHERE to_tsvector('simple', unaccent(COALESCE("projects"."name"::text, '')))
          @@ to_tsquery('simple', '''upkeep'':*')
        ORDER BY "pg_search_rank" DESC, "projects"."created_at" DESC
      SQL
      tables: ["projects"]
    )
  ].freeze

  PG_SEARCH_WITH_WORD_SIMILARITY_OPERATOR = <<~SQL
    SELECT "projects".*
    FROM "projects"
    WHERE to_tsvector('simple', unaccent(COALESCE("projects"."name"::text, '')))
        @@ to_tsquery('simple', '''upkeep'':*')
      OR 'upkeep' <% unaccent(COALESCE("projects"."name"::text, ''))
  SQL

  CASES.each do |query_case|
    define_method("test_#{query_case.name.gsub(/[^a-z0-9]+/i, "_").downcase}") do
      assert_equal(
        query_case.tables.sort,
        SqlglotDependencyExtractor.tables(query_case.sql, dialect: :postgres),
        query_case.pr_source
      )
    end
  end

  def test_convenience_api_undercounts_nested_physical_sources
    nested_cases = CASES.select { |query_case| query_case.tables.length > 1 }

    misses = nested_cases.filter_map do |query_case|
      actual = Sqlglot::Query.new(query_case.sql, dialect: :postgres).tables.sort
      query_case.name unless actual == query_case.tables.sort
    end

    assert_equal(
      [
        "correlated aggregate scalar subquery",
        "case expression with repeated correlated exists"
      ],
      misses
    )
  end

  def test_pg_search_word_similarity_operator_is_not_supported
    error = assert_raises(Sqlglot::ParseError) do
      SqlglotDependencyExtractor.tables(
        PG_SEARCH_WITH_WORD_SIMILARITY_OPERATOR,
        dialect: :postgres
      )
    end

    assert_includes error.message, "<%"
  end

  def test_pg_search_failure_minimizes_to_pg_trgm_operator
    Sqlglot.parse(
      "SELECT * FROM projects WHERE vector @@ to_tsquery('simple', 'upkeep:*')",
      dialect: :postgres
    )
    Sqlglot.parse(
      "SELECT word_similarity('upkeep', name) FROM projects",
      dialect: :postgres
    )

    assert_raises(Sqlglot::ParseError) do
      Sqlglot.parse(
        "SELECT * FROM projects WHERE 'upkeep' <% name",
        dialect: :postgres
      )
    end
  end
end
