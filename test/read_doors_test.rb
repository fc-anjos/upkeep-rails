require_relative "test_helper"

# Read-door coverage beyond materialization (calculate/pluck/exists? at the
# Relation level, statement-cache binds for find/find_by), plus the
# completeness audit: any SELECT during capture that no door accounts for
# either degrades to a table-level dependency (attributable via the query
# name) or refuses the capture outright (unattributable) — always loudly.
class ReadDoorsTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def capture_events(pattern)
    events = []
    sub = ActiveSupport::Notifications.subscribe(pattern) { |*_a, payload| events << payload }
    yield events
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def stream_for(path)
    get path
    assert_response :success
    response.headers["X-Upkeep-Stream"]
  end

  def test_count_page_depends_on_the_counted_predicate
    capture_events("capture_incomplete.upkeep") do |events|
      stream = stream_for("/doors/open_count")
      assert stream, "count-only page must register a cohort"
      deps = Upkeep::Capture.last_recording.read_set.tables.fetch("cards")
      assert_includes deps.aggregates,
        { "fn" => "count", "column" => nil, "group" => [],
          "predicates" => [{ "status" => ["open"] }] },
        "the calculate door must record the counted predicate inside a count descriptor"
      assert_empty events, "hooked doors must not trip the audit"

      Card.create!(board: @board1, title: "Newly open", status: "open")
      assert_refreshes(stream, 1)
      broadcasts(stream).clear rescue nil
    end
  end

  def test_count_page_ignores_rows_outside_the_predicate
    stream = stream_for("/doors/open_count")
    Card.create!(board: @board1, title: "Closed", status: "done")
    assert_no_refresh(stream)
  end

  # A count sees membership only: an in-place content move inside the
  # counted set is provably invisible to it and schedules nothing.
  def test_count_page_ignores_in_place_content_moves
    stream = stream_for("/doors/open_count")
    @card1.update!(title: "Renamed, still open")
    assert_no_refresh(stream)
  end

  def test_pluck_page_depends_on_the_plucked_predicate
    stream = stream_for("/doors/open_titles")
    deps = Upkeep::Capture.last_recording.read_set.tables.fetch("cards")
    assert_includes deps.predicates, { "status" => ["open"] }
    @card1.update!(title: "First (renamed)")
    assert_refreshes(stream, 1)
  end

  def test_exists_page_depends_on_the_tested_predicate
    stream = stream_for("/doors/any_open")
    deps = Upkeep::Capture.last_recording.read_set.tables.fetch("cards")
    assert_includes deps.membership_predicates, { "status" => ["open"] }
    Card.create!(board: @board1, title: "Another open", status: "open")
    assert_refreshes(stream, 1)
  end

  # The statement-cache nil-result hole: find_by that found nothing used to
  # record NOTHING (no materialization), so the row's later insert was
  # silently missed. The bind-map door records the predicate either way.
  def test_nil_result_find_by_still_records_its_predicate
    stream = stream_for("/doors/lost_card")
    deps = Upkeep::Capture.last_recording.read_set.tables.fetch("cards")
    assert deps.predicates.any? { |p| p["uid"] == ["lost-uid"] },
      "the cached find_by predicate must be recorded despite the nil result: #{deps.predicates.inspect}"
    Card.create!(board: @board1, title: "Found me", status: "open", uid: "lost-uid")
    assert_refreshes(stream, 1)
  end

  def test_unhooked_attributable_read_degrades_to_table_level_loudly
    capture_events("capture_incomplete.upkeep") do |events|
      stream = stream_for("/doors/raw_named")
      assert stream, "an attributable unhooked read keeps the page live (conservatively)"
      assert events.any? { |p| p[:mode] == :degraded_table_level && p[:table] == "cards" },
        "the audit must warn loudly: #{events.inspect}"
      deps = Upkeep::Capture.last_recording.read_set.tables.fetch("cards")
      assert_includes deps.table_reasons, :unhooked_read_door
      assert_operator Upkeep.stats[:unhooked_reads_degraded], :>=, 1

      # Conservative means table-level: even a write no predicate could
      # match refreshes the page instead of leaving it silently stale.
      Card.create!(board: @board2, title: "Unrelated", status: "done")
      assert_refreshes(stream, 1)
    end
  end

  # Strict mode (the raise itself) is covered in legibility_test; this
  # asserts the production warn-and-refuse path stays intact underneath.
  # The refusal now requires a read even the PARSER cannot attribute (no
  # table at all) — anything with parseable table names degrades instead.
  def test_unhooked_unattributable_read_refuses_the_capture_loudly
    capture_events("capture_refused.upkeep") do |refusals|
      capture_events("capture_incomplete.upkeep") do |events|
        no_raise { get "/doors/raw_scalar" }
        assert_response :success
        assert_nil response.headers["X-Upkeep-Stream"],
          "an unattributable unhooked read must refuse cohort registration"
        assert events.any? { |p| p[:mode] == :unattributable }
        assert refusals.any? { |p| p[:reason] == :unattributable_read && p[:path] == "/doors/raw_scalar" },
          "the refusal must be loud: #{refusals.inspect}"
        assert_equal 1, Upkeep.stats[:captures_refused]
      end
    end
  end

  # Liveness LOST becomes liveness COARSENED: an anonymous raw read whose
  # SQL the parser can attribute registers conservative table-level
  # dependencies instead of refusing capture.
  def test_parser_attributes_anonymous_raw_read_to_its_tables
    capture_events("capture_incomplete.upkeep") do |events|
      stream = nil
      no_raise do
        get "/doors/raw_anonymous"
        assert_response :success
        stream = response.headers["X-Upkeep-Stream"]
      end
      assert stream, "a parser-attributable read must still register a cohort"
      assert events.any? { |p| p[:mode] == :degraded_table_level && p[:tables] == ["cards"] },
        "the coarsening must be loud: #{events.inspect}"
      assert_equal 0, Upkeep.stats[:captures_refused]

      # Table-level means conservative: any write to cards refreshes.
      Card.create!(board: @board2, title: "Unrelated", status: "done")
      assert_refreshes(stream, 1)
    end
  end
end

# G-batch precision: joined-table predicates, find_each identity, datetime
# coercion round-trips.
class PrecisionDebtsTest < ActiveSupport::TestCase
  include ProofHelpers

  def capture
    recording = Upkeep::Recording.start
    yield
    recording
  ensure
    Upkeep::Recording.finish
  end

  def test_joined_table_conditions_become_that_tables_predicate
    recording = capture do
      Board.joins(:cards).where(cards: { status: "open" }).to_a
    end
    deps = recording.read_set.tables["cards"]
    assert deps, "joined table stays a dependency"
    assert_empty deps.table_reasons, "conditions on the joined table's own columns analyze"
    assert(deps.predicates.any? { |p| p["status"] == ["open"] })

    hit = Upkeep::Change.new(table: "cards", id: 999, kind: :update,
                                  new_attrs: { "id" => 999, "status" => "open" })
    miss = Upkeep::Change.new(table: "cards", id: 999, kind: :update,
                                   new_attrs: { "id" => 999, "status" => "archived" },
                                   old_attrs: { "id" => 999, "status" => "archived" })
    assert recording.read_set.matches?(hit)
    refute recording.read_set.matches?(miss),
      "a row never satisfying the join condition cannot affect the join result"
  end

  def test_unconstrained_joins_stay_table_level
    recording = capture { Board.joins(:cards).to_a }
    assert_includes recording.read_set.tables["cards"].table_reasons, :joined_table
  end

  def test_find_each_records_every_batchs_ids
    cards = 5.times.map { |i| Card.create!(board: @board1, title: "Batch #{i}", status: "open") }
    recording = capture do
      Card.where(status: "open").find_each(batch_size: 2) { |c| c.title }
    end
    deps = recording.read_set.tables["cards"]
    cards.each { |c| assert_includes deps.ids, c.id }
  end

  def test_datetime_predicates_survive_json_round_trips
    due = Date.new(2026, 8, 6)
    Card.create!(board: @board1, title: "Dated", status: "open", due_on: due)
    recording = capture { Card.where(due_on: due).to_a }
    revived = Upkeep::ReadSet.from_h(JSON.parse(JSON.generate(recording.read_set.to_h)))
    change = Upkeep::Change.new(table: "cards", id: 999, kind: :update,
                                     new_attrs: { "id" => 999, "due_on" => due })
    assert revived.matches?(change),
      "a JSON-reloaded date predicate must still match a live Date write"
  end
end
