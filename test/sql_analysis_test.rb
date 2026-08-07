# The parser doorway: the capped shape cache (rule zero) and the compiled
# three-valued fragment predicates (rule one — every failure must land on
# the conservative side). Census shapes throughout: date windows with
# OR/IS NULL, ILIKE, BETWEEN, IN, extract()/casts (matchable-only),
# relative SET lists, aliased subquery joins.
require "test_helper"

class SqlAnalysisTest < ActiveSupport::TestCase
  def setup
    Upkeep::SqlAnalysis.reset!
    Upkeep::Coercion.reset!
  end

  def fragment(sql, binds: [], table: "cards", **kwargs)
    Upkeep::SqlAnalysis.fragment(sql, table: table, binds: binds, **kwargs)
  end

  def evaluate(frag, attrs, table: "cards")
    Upkeep::SqlPredicate.evaluate(frag, table, attrs)
  end

  # -- compilation ----------------------------------------------------------

  def test_date_window_fragment_compiles_evaluable_with_binds_separate
    frag = fragment("start_date <= ? AND (end_date IS NULL OR end_date >= ?)",
                    binds: [Date.new(2026, 6, 1), Date.new(2026, 6, 1)],
                    table: "assignments")
    assert frag["evaluable"]
    assert_equal %w[start_date end_date], frag["columns"]
    assert_equal %w[2026-06-01 2026-06-01], frag["binds"]
  end

  def test_shape_is_parsed_once_and_binds_ride_separately
    2.times { |i| fragment("title LIKE ?", binds: ["%x#{i}%"]) }
    stats = Upkeep::SqlAnalysis.cache_stats
    assert_operator stats[:hits], :>=, 1, "second identical shape must hit the cache"
  end

  def test_parse_failure_is_a_permanent_opaque_entry
    2.times { assert_nil fragment("this is (((not sql") }
    assert_operator Upkeep::SqlAnalysis.cache_stats[:hits], :>=, 1,
      "the failed parse must be cached, not retried"
  end

  def test_cache_is_capped
    cap = Upkeep::SqlAnalysis::MAX_ENTRIES
    (cap + 50).times { |i| fragment("title = 'shape#{i}'") }
    # Re-request the very first shape: it must have been evicted (a miss),
    # yet still answer correctly.
    before = Upkeep::SqlAnalysis.cache_stats[:misses]
    frag = fragment("title = 'shape0'")
    assert_equal before + 1, Upkeep::SqlAnalysis.cache_stats[:misses]
    assert frag["evaluable"]
  end

  def test_function_wrapped_column_is_matchable_but_not_evaluable
    frag = fragment("extract(year from due_on) = 2026")
    assert_equal ["due_on"], frag["columns"], "the column survives for matching"
    refute frag["evaluable"]
    assert_nil evaluate(frag, { "due_on" => "2026-05-01" }),
      "a function call must evaluate UNKNOWN, never guess"
  end

  def test_cast_column_is_matchable_but_not_evaluable
    frag = fragment("due_on::DATE = '2026-01-01'")
    # SQLite's dialect may reject ::, postgres parses it — either outcome
    # is conservative; when it parses, the column must survive.
    skip "dialect rejects ::" if frag.nil?
    assert_equal ["due_on"], frag["columns"]
    refute frag["evaluable"]
  end

  def test_fragment_referencing_another_table_is_opaque
    assert_nil fragment("board_id IN (SELECT id FROM boards)"),
      "a subquery on another table cannot be vouched for"
    assert_nil fragment("boards.name = 'x'")
  end

  def test_named_binds_stay_conservative
    node = Card.where("status = :s", s: "open").where_clause.ast
    assert_nil Upkeep::SqlAnalysis.arel_fragment(node)
  end

  # -- three-valued evaluation ----------------------------------------------

  def test_date_window_evaluation
    frag = fragment("start_date <= ? AND (end_date IS NULL OR end_date >= ?)",
                    binds: ["2026-06-01", "2026-06-01"], table: "assignments")
    inside = { "start_date" => "2026-05-01", "end_date" => nil }
    ended = { "start_date" => "2026-05-01", "end_date" => "2026-05-20" }
    future = { "start_date" => "2026-07-01", "end_date" => nil }
    assert_equal true, evaluate(frag, inside, table: "assignments")
    assert_equal false, evaluate(frag, ended, table: "assignments")
    assert_equal false, evaluate(frag, future, table: "assignments")
    assert_nil evaluate(frag, { "start_date" => "2026-05-01" }, table: "assignments"),
      "missing end_date must be UNKNOWN, not guessed"
  end

  def test_like_and_ilike_evaluation
    like = fragment("title LIKE ?", binds: ["%need%"])
    assert_equal true, evaluate(like, { "title" => "needs attention" })
    assert_equal false, evaluate(like, { "title" => "NEEDS attention" }),
      "LIKE is case-sensitive"
    ilike = fragment("title ILIKE ?", binds: ["%need%"])
    assert_equal true, evaluate(ilike, { "title" => "NEEDS attention" })
    assert_nil evaluate(ilike, { "title" => nil }), "NULL LIKE anything is UNKNOWN"
  end

  def test_between_in_and_not_evaluation
    between = fragment("position BETWEEN ? AND ?", binds: [1, 5], table: "items")
    assert_equal true, evaluate(between, { "position" => 3 }, table: "items")
    assert_equal false, evaluate(between, { "position" => 9 }, table: "items")
    inlist = fragment("status IN ('open', 'held')")
    assert_equal true, evaluate(inlist, { "status" => "held" })
    assert_equal false, evaluate(inlist, { "status" => "done" })
    negated = fragment("NOT (status = 'open')")
    assert_equal false, evaluate(negated, { "status" => "open" })
    assert_equal true, evaluate(negated, { "status" => "done" })
  end

  def test_coercion_applies_column_types
    frag = fragment("due_on >= ?", binds: [Date.new(2026, 1, 1)])
    assert_equal true, evaluate(frag, { "due_on" => Date.new(2026, 2, 2) })
    assert_equal true, evaluate(frag, { "due_on" => "2026-02-02" }),
      "a JSON-reloaded string must compare as a date"
  end

  def test_verdict_integration_enter_leave_irrelevant
    frag = fragment("due_on >= ?", binds: ["2026-06-01"])
    pred = { "__fragment__" => frag }
    fact = ->(old_due, new_due) do
      Upkeep::Fact.new(table: "cards", id: 1, kind: :update,
                       old_attrs: { "due_on" => old_due, "id" => 1 },
                       new_attrs: { "due_on" => new_due, "id" => 1 },
                       columns: ["due_on"])
    end
    deps = Upkeep::ReadSet::Deps.new(Set.new, [pred], [], [])
    assert_equal :enter, Upkeep::Verdict.of(deps, fact.call("2026-01-01", "2026-07-01"))
    assert_equal :leave, Upkeep::Verdict.of(deps, fact.call("2026-07-01", "2026-01-01"))
    assert_equal :irrelevant, Upkeep::Verdict.of(deps, fact.call("2026-01-01", "2026-02-01"))
    assert_equal :in_place, Upkeep::Verdict.of(deps, fact.call("2026-07-01", "2026-08-01"))
  end

  def test_unknown_before_with_disjoint_write_borrows_after
    frag = fragment("due_on >= ?", binds: ["2026-06-01"])
    pred = { "__fragment__" => frag }
    deps = Upkeep::ReadSet::Deps.new(Set.new, [pred], [], [])
    # Bulk write to title only: predicate columns (due_on) disjoint, after
    # values known — the unknown before borrows the after answer.
    fact = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :update,
                            ids: [1], columns: ["title"],
                            rows: { 1 => { "due_on" => "2026-01-01", "title" => "x" } })
    assert_equal :irrelevant, Upkeep::Verdict.of(deps, fact)
  end

  def test_opaque_fragment_columns_never_look_disjoint
    frag = fragment("length(title) > 3")
    frag["columns"] = [] # simulate a shape whose columns could not be harvested
    pred = { "__fragment__" => frag }
    refute Upkeep::Verdict.columns_disjoint?(pred, ["anything"]),
      "unknown predicate columns must never enable the disjoint-write borrow"
  end

  # -- raw-string SET extraction --------------------------------------------

  def test_raw_set_columns_extracted
    assert_equal %w[position updated_at],
      Upkeep::SqlAnalysis.set_columns("items", "position = position + 1, updated_at = CURRENT_TIMESTAMP")
  end

  def test_unparseable_set_stays_all_columns
    assert_nil Upkeep::SqlAnalysis.set_columns("items", "position = position + WHERE nonsense")
  end

  # -- statement table extraction (audit attribution) -----------------------

  def test_statement_tables_extracts_physical_tables
    assert_equal ["cards"], Upkeep::SqlAnalysis.statement_tables("SELECT COUNT(*) AS c FROM cards")
    assert_equal %w[boards cards],
      Upkeep::SqlAnalysis.statement_tables(
        "SELECT c.id FROM cards c JOIN boards b ON b.id = c.board_id"
      )
  end

  def test_statement_tables_empty_for_tableless_and_nil_for_garbage
    assert_equal [], Upkeep::SqlAnalysis.statement_tables("SELECT 1")
    assert_nil Upkeep::SqlAnalysis.statement_tables("COMPLETELY (((not sql")
  end

  # -- string-join alias resolution -----------------------------------------

  def test_join_analysis_resolves_aliased_subquery_to_physical_tables
    analysis = Upkeep::SqlAnalysis.join_analysis(
      "items",
      "LEFT JOIN (SELECT item_id, MAX(score) AS top_score FROM reviews GROUP BY item_id) " \
      "latest_reviews ON latest_reviews.item_id = items.id"
    )
    assert_equal ["reviews"], analysis[:tables]
    assert_equal :scope, analysis[:aliases]["latest_reviews"]
  end

  def test_join_analysis_resolves_direct_alias
    analysis = Upkeep::SqlAnalysis.join_analysis(
      "cards", "INNER JOIN boards b ON b.id = cards.board_id"
    )
    assert_equal ["boards"], analysis[:tables]
    assert_equal "boards", analysis[:aliases]["b"]
  end

  def test_join_analysis_nil_for_garbage
    assert_nil Upkeep::SqlAnalysis.join_analysis("cards", "JOIN ((( nonsense")
  end

  # -- hit cost (rule zero) -------------------------------------------------

  def test_cache_hit_cost_is_microseconds
    fragment("title LIKE ?", binds: ["%warm%"])
    runs = 2_000
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    runs.times { fragment("title LIKE ?", binds: ["%warm%"]) }
    per_hit_us = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / runs * 1_000_000
    assert_operator per_hit_us, :<, 50,
      "a cache hit must stay far under a parse (~55us); measured #{per_hit_us.round(2)}us"
  end
end
