# frozen_string_literal: true

require "minitest/autorun"
require "sqlglot"
require_relative "sqlglot_dependency_extractor"

class SqlglotQueryAnalysisTest < Minitest::Test
  Case = Data.define(:name, :dialect, :sql, :tables)

  CASES = [
    Case.new(
      name: "SQLite raw predicate and order",
      dialect: :sqlite,
      sql: <<~SQL,
        SELECT "stories".*
        FROM "stories"
        WHERE (score >= 0)
        ORDER BY created_at DESC
      SQL
      tables: ["stories"]
    ),
    Case.new(
      name: "SQLite raw join",
      dialect: :sqlite,
      sql: <<~SQL,
        SELECT "users".*
        FROM "users"
        INNER JOIN posts ON posts.user_id = users.id
        WHERE posts.published = 1
      SQL
      tables: %w[posts users]
    ),
    Case.new(
      name: "SQLite correlated EXISTS subquery",
      dialect: :sqlite,
      sql: <<~SQL,
        SELECT "users".*
        FROM "users"
        WHERE EXISTS (
          SELECT 1
          FROM posts
          WHERE posts.user_id = users.id
        )
      SQL
      tables: %w[posts users]
    ),
    Case.new(
      name: "SQLite derived table",
      dialect: :sqlite,
      sql: <<~SQL,
        SELECT recent_posts.*
        FROM (
          SELECT posts.*
          FROM posts
          WHERE posts.created_at >= '2026-01-01'
        ) recent_posts
      SQL
      tables: ["posts"]
    ),
    Case.new(
      name: "SQLite CTE",
      dialect: :sqlite,
      sql: <<~SQL,
        WITH recent_posts AS (
          SELECT posts.*
          FROM posts
          WHERE posts.created_at >= '2026-01-01'
        )
        SELECT recent_posts.*
        FROM recent_posts
      SQL
      tables: ["posts"]
    ),
    Case.new(
      name: "SQLite CTE shadows a physical table",
      dialect: :sqlite,
      sql: <<~SQL,
        WITH posts AS (
          SELECT physical_posts.*
          FROM main.posts AS physical_posts
          WHERE physical_posts.published = 1
        )
        SELECT posts.*
        FROM posts
      SQL
      tables: ["main.posts"]
    ),
    Case.new(
      name: "PostgreSQL recursive CTE",
      dialect: :postgres,
      sql: <<~SQL,
        WITH RECURSIVE descendants AS (
          SELECT nodes.*
          FROM nodes
          WHERE nodes.parent_id IS NULL
          UNION ALL
          SELECT nodes.*
          FROM nodes
          JOIN descendants ON descendants.id = nodes.parent_id
        )
        SELECT descendants.*
        FROM descendants
      SQL
      tables: ["nodes"]
    ),
    Case.new(
      name: "PostgreSQL full-text search",
      dialect: :postgres,
      sql: <<~SQL,
        SELECT "stories".*
        FROM "stories"
        WHERE (
          stories.search_vector @@ plainto_tsquery('english', 'rails')
        )
        ORDER BY ts_rank(
          stories.search_vector,
          plainto_tsquery('english', 'rails')
        ) DESC
      SQL
      tables: ["stories"]
    ),
    Case.new(
      name: "PostgreSQL schema-qualified join",
      dialect: :postgres,
      sql: <<~SQL,
        SELECT accounts.*
        FROM public.accounts
        JOIN audit.events ON events.account_id = accounts.id
        WHERE events.kind = 'login'
      SQL
      tables: %w[audit.events public.accounts]
    ),
    Case.new(
      name: "PostgreSQL nested IN subquery",
      dialect: :postgres,
      sql: <<~SQL,
        SELECT projects.*
        FROM projects
        WHERE projects.id IN (
          SELECT memberships.project_id
          FROM memberships
          WHERE memberships.user_id = 42
        )
      SQL
      tables: %w[memberships projects]
    ),
    Case.new(
      name: "MySQL JSON predicate",
      dialect: :mysql,
      sql: <<~SQL,
        SELECT `documents`.*
        FROM `documents`
        WHERE JSON_UNQUOTE(JSON_EXTRACT(`documents`.`metadata`, '$.status')) = 'open'
      SQL
      tables: ["documents"]
    ),
    Case.new(
      name: "MySQL derived table join",
      dialect: :mysql,
      sql: <<~SQL,
        SELECT users.*
        FROM users
        JOIN (
          SELECT orders.user_id
          FROM orders
          WHERE orders.state = 'paid'
        ) paid_orders ON paid_orders.user_id = users.id
      SQL
      tables: %w[orders users]
    )
  ].freeze

  CASES.each do |query_case|
    define_method("test_#{query_case.name.downcase.gsub(/[^a-z0-9]+/, "_")}") do
      assert_equal(
        query_case.tables.sort,
        SqlglotDependencyExtractor.tables(query_case.sql, dialect: query_case.dialect)
      )
    end
  end

  def test_wrapper_metadata_helper_misses_nested_sources
    query_case = CASES.find { |candidate| candidate.name == "SQLite correlated EXISTS subquery" }
    query = Sqlglot::Query.new(query_case.sql, dialect: query_case.dialect)

    assert_equal ["users"], query.tables
    assert_equal %w[posts users], SqlglotDependencyExtractor.tables(query_case.sql, dialect: query_case.dialect)
  end

  def test_parse_failure_is_an_explicit_error
    assert_raises(Sqlglot::ParseError) do
      Sqlglot::Query.new("SELECT FROM", dialect: :postgres).tables
    end
  end
end
