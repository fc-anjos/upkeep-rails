# frozen_string_literal: true

# The SQLGlot Rust binding: Upkeep's native SQL parser. Deliberately
# Rails-free (no test_helper) so the native-package CI can run it on a bare
# ruby with just ffi installed. Covers: parsing the SQL shapes Rails
# actually generates in the three bundled-adapter dialects, the
# schema-aware semantic API (qualify/scope/lineage), the error taxonomy
# (garbage must raise, never partially succeed), and the Postgres JSON
# path operators #>/#>> that upstream v0.10.27 still silently truncates
# without our patch.
require "minitest/autorun"
require "upkeep/sqlglot"

class SQLGlotTest < Minitest::Test
  SCHEMA = Upkeep::SQLGlot::MappingSchema.new(
    {
      "cards" => { "id" => "INTEGER", "project_id" => "INTEGER", "status" => "TEXT" },
      "projects" => { "id" => "INTEGER", "name" => "TEXT" }
    },
    dialect: :postgres
  )

  def test_version_reports_the_pinned_crate
    assert_equal "0.10.27", Upkeep::SQLGlot.version
  end

  # -- Rails-generated statement shapes, per bundled adapter dialect --------

  def test_parses_rails_select_with_binds_in_each_adapter_dialect
    {
      sqlite: %q{SELECT "cards".* FROM "cards" WHERE "cards"."project_id" = ? LIMIT ?},
      postgres: %q{SELECT "cards".* FROM "cards" WHERE "cards"."project_id" = $1 LIMIT $2},
      mysql: "SELECT `cards`.* FROM `cards` WHERE `cards`.`project_id` = ? LIMIT ?"
    }.each do |dialect, sql|
      ast = Upkeep::SQLGlot.parse(sql, dialect: dialect)
      select = ast.fetch("Select")

      assert_equal [{ "QualifiedWildcard" => { "table" => "cards" } }],
        select.fetch("columns"), "#{dialect}: projection must survive"
      where = select.fetch("where_clause").fetch("BinaryOp")
      assert_equal "project_id", where.fetch("left").fetch("Column").fetch("name"),
        "#{dialect}: bind predicate column must survive"
    end
  end

  def test_parses_rails_update_with_set_clause
    sql = %q{UPDATE "cards" SET "status" = ?, "updated_at" = ? WHERE "cards"."id" = ?}
    update = Upkeep::SQLGlot.parse(sql, dialect: :sqlite).fetch("Update")

    assert_equal "cards", update.fetch("table").fetch("name")
    assert_equal %w[status updated_at], update.fetch("assignments").map(&:first)
  end

  def test_parses_rails_delete
    sql = %q{DELETE FROM "cards" WHERE "cards"."id" = ?}
    delete = Upkeep::SQLGlot.parse(sql, dialect: :sqlite).fetch("Delete")

    assert_equal "cards", delete.fetch("table").fetch("name")
    assert_equal "id",
      delete.fetch("where_clause").fetch("BinaryOp").fetch("left")
        .fetch("Column").fetch("name")
  end

  def test_parses_join_with_aliases_and_generates_back
    sql = "SELECT c.id, p.name FROM cards AS c " \
      "INNER JOIN projects AS p ON p.id = c.project_id WHERE c.status = 'open'"
    ast = Upkeep::SQLGlot.parse(sql, dialect: :postgres)

    assert_equal sql, Upkeep::SQLGlot.generate(ast, dialect: :postgres)
  end

  # -- Schema-aware semantic analysis ---------------------------------------

  def test_qualify_columns_attributes_bare_columns_to_their_tables
    ast = Upkeep::SQLGlot.parse(
      "SELECT status, name FROM cards JOIN projects ON projects.id = cards.project_id",
      dialect: :postgres
    )
    qualified = Upkeep::SQLGlot.generate(
      Upkeep::SQLGlot.qualify_columns(ast, SCHEMA),
      dialect: :postgres
    )

    assert_includes qualified, "cards.status", "status belongs to cards"
    assert_includes qualified, "projects.name", "name belongs to projects"
  end

  def test_build_scope_reports_per_source_column_usage
    ast = Upkeep::SQLGlot.parse(
      "SELECT c.id, p.name FROM cards AS c " \
        "JOIN projects AS p ON p.id = c.project_id WHERE c.status = 'open'",
      dialect: :postgres
    )
    scope = Upkeep::SQLGlot.build_scope(ast)

    assert_equal :root, scope.scope_type
    assert_equal %w[c p], scope.sources.keys.sort
    assert_equal "cards", scope.sources.fetch("c").table.name
    used = scope.columns.map { |column| [column.table, column.name] }
    assert_includes used, ["c", "status"]
    assert_includes used, ["p", "name"]
  end

  def test_scope_walk_descends_into_subqueries
    ast = Upkeep::SQLGlot.parse(
      "SELECT id FROM (SELECT id FROM cards WHERE status = 'open') AS open_cards",
      dialect: :postgres
    )
    scopes = Upkeep::SQLGlot.build_scope(ast).walk.to_a

    assert_equal 2, scopes.length, "root scope plus the derived-table scope"
    assert scopes.any? { |scope| scope.sources.values.any? { |source| source.table&.name == "cards" } }
  end

  def test_lineage_traces_a_projected_column_to_its_source_table
    ast = Upkeep::SQLGlot.parse(
      "SELECT c.id, p.name FROM cards AS c JOIN projects AS p ON p.id = c.project_id",
      dialect: :postgres
    )
    graph = Upkeep::SQLGlot.lineage(
      "name",
      Upkeep::SQLGlot.qualify_columns(ast, SCHEMA),
      SCHEMA
    )

    assert_equal ["p"], graph.source_tables, "name comes from projects (alias p) only"
  end

  # -- Error taxonomy: loud failure, never partial success ------------------

  def test_garbage_raises_parse_error
    assert_raises(Upkeep::SQLGlot::ParseError) do
      Upkeep::SQLGlot.parse("SELECT FROM WHERE garbage(((", dialect: :postgres)
    end
  end

  def test_unknown_dialect_raises_argument_error
    assert_raises(ArgumentError) do
      Upkeep::SQLGlot.parse("SELECT 1", dialect: :access97)
    end
  end

  def test_malformed_ast_raises_generate_error
    assert_raises(Upkeep::SQLGlot::GenerateError) do
      Upkeep::SQLGlot.generate({ "NotAStatement" => {} }, dialect: :postgres)
    end
  end

  # -- Postgres JSON path operators: the local patch, pinned ----------------
  # Upstream v0.10.27 tokenizes #>/#>> but its parser drops everything from
  # the operator onward — a silent partial parse. The build applies
  # ext/sqlglot_rust/patches/postgres_json_path_operators.patch until
  # upstream parses them. If this test fails after a crate bump, either the
  # patch stopped applying or upstream changed the AST shape.
  def test_postgres_json_path_operators_roundtrip
    sql = "SELECT data #> '{a,b}', data #>> '{a,b}' FROM t"
    ast = Upkeep::SQLGlot.parse(sql, dialect: :postgres)

    accesses = ast.fetch("Select").fetch("columns").map do |column|
      column.fetch("Expr").fetch("expr").fetch("JsonAccess")
    end
    assert_equal [false, true], accesses.map { |access| access.fetch("as_text") }
    assert(accesses.all? { |access| access.fetch("path_array") })
    assert_equal sql, Upkeep::SQLGlot.generate(ast, dialect: :postgres)
  end
end
