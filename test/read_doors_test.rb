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
    response.headers["X-RefreshSync-Stream"]
  end

  def test_count_page_depends_on_the_counted_predicate
    capture_events("capture_incomplete.refresh_sync") do |events|
      stream = stream_for("/doors/open_count")
      assert stream, "count-only page must register a cohort"
      deps = RefreshSync::Capture.last_recording.read_set.tables.fetch("cards")
      assert_includes deps.predicates, { "status" => ["open"] },
        "the calculate door must record the counted predicate"
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

  def test_pluck_page_depends_on_the_plucked_predicate
    stream = stream_for("/doors/open_titles")
    deps = RefreshSync::Capture.last_recording.read_set.tables.fetch("cards")
    assert_includes deps.predicates, { "status" => ["open"] }
    @card1.update!(title: "First (renamed)")
    assert_refreshes(stream, 1)
  end

  def test_exists_page_depends_on_the_tested_predicate
    stream = stream_for("/doors/any_open")
    deps = RefreshSync::Capture.last_recording.read_set.tables.fetch("cards")
    assert_includes deps.predicates, { "status" => ["open"] }
    Card.create!(board: @board1, title: "Another open", status: "open")
    assert_refreshes(stream, 1)
  end

  # The statement-cache nil-result hole: find_by that found nothing used to
  # record NOTHING (no materialization), so the row's later insert was
  # silently missed. The bind-map door records the predicate either way.
  def test_nil_result_find_by_still_records_its_predicate
    stream = stream_for("/doors/lost_card")
    deps = RefreshSync::Capture.last_recording.read_set.tables.fetch("cards")
    assert deps.predicates.any? { |p| p["uid"] == ["lost-uid"] },
      "the cached find_by predicate must be recorded despite the nil result: #{deps.predicates.inspect}"
    Card.create!(board: @board1, title: "Found me", status: "open", uid: "lost-uid")
    assert_refreshes(stream, 1)
  end

  def test_unhooked_attributable_read_degrades_to_table_level_loudly
    capture_events("capture_incomplete.refresh_sync") do |events|
      stream = stream_for("/doors/raw_named")
      assert stream, "an attributable unhooked read keeps the page live (conservatively)"
      assert events.any? { |p| p[:mode] == :degraded_table_level && p[:table] == "cards" },
        "the audit must warn loudly: #{events.inspect}"
      deps = RefreshSync::Capture.last_recording.read_set.tables.fetch("cards")
      assert_includes deps.table_reasons, :unhooked_read_door
      assert_operator RefreshSync.stats[:unhooked_reads_degraded], :>=, 1

      # Conservative means table-level: even a write no predicate could
      # match refreshes the page instead of leaving it silently stale.
      Card.create!(board: @board2, title: "Unrelated", status: "done")
      assert_refreshes(stream, 1)
    end
  end

  def test_unhooked_unattributable_read_refuses_the_capture_loudly
    capture_events("capture_refused.refresh_sync") do |refusals|
      capture_events("capture_incomplete.refresh_sync") do |events|
        get "/doors/raw_anonymous"
        assert_response :success
        assert_nil response.headers["X-RefreshSync-Stream"],
          "an unattributable unhooked read must refuse cohort registration"
        assert events.any? { |p| p[:mode] == :unattributable }
        assert refusals.any? { |p| p[:reason] == :unattributable_read && p[:path] == "/doors/raw_anonymous" },
          "the refusal must be loud: #{refusals.inspect}"
        assert_equal 1, RefreshSync.stats[:captures_refused]
      end
    end
  end
end
