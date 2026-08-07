# End-to-end census wins: fragment predicates matching and evaluating on
# real captured pages, raw-SET column extraction on the hottest write path,
# string-join table attribution, and temporal-literal expiry. Every
# precision case is paired with a neighbor proving the conservative path
# still fires.
require "test_helper"

class FragmentPrecisionTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def setup
    super
    Assignment.delete_all
    Review.delete_all
    Item.delete_all
  end

  # -- 1. date-window fragment: writes outside the predicate cost nothing --

  def test_date_window_page_ignores_out_of_window_writes
    Assignment.create!(title: "Current", start_date: "2026-05-01", end_date: nil)
    past = Assignment.create!(title: "Ended", start_date: "2026-01-01", end_date: "2026-02-01")

    get "/census/active_assignments", params: { on: "2026-06-15" }
    assert_response :success
    stream = response.headers["X-Upkeep-Stream"]
    assert stream, "the fragment page must register a cohort"

    # A write to a row provably outside the window: no refresh at all.
    past.update!(title: "Renamed ended")
    assert_no_refresh(stream)
  end

  def test_date_window_page_refreshes_on_enter_and_in_window_writes
    current = Assignment.create!(title: "Current", start_date: "2026-05-01", end_date: nil)
    get "/census/active_assignments", params: { on: "2026-06-15" }
    stream = response.headers["X-Upkeep-Stream"]

    # In-place change to a member row refreshes.
    current.update!(title: "Current, renamed")
    assert_refreshes(stream, 1)

    # A row ENTERING the window refreshes (insert matching the predicate).
    Assignment.create!(title: "New", start_date: "2026-06-01", end_date: nil)
    assert_refreshes(stream, 2)
  end

  def test_like_search_page_matches_by_pattern
    get "/census/search", params: { q: "First" }
    stream = response.headers["X-Upkeep-Stream"]

    # A card that does not match the LIKE pattern: irrelevant.
    Card.create!(title: "Zebra", status: "open")
    assert_no_refresh(stream)

    # A card matching the pattern enters the page.
    Card.create!(title: "First contact", status: "open")
    assert_refreshes(stream, 1)
  end

  # Neighbor: a function-wrapped column is matchable but NOT evaluable —
  # every write to that column stays conservative (refresh).
  def test_function_fragment_stays_conservative
    Card.create!(title: "Long enough title")
    get "/census/long_titles", params: { min: 5 }
    stream = response.headers["X-Upkeep-Stream"]

    # Verdict cannot evaluate length(title): conservative refresh, even for
    # a short title that would not match.
    Card.create!(title: "abc")
    assert_refreshes(stream, 1)
  end

  # -- 2. raw-string SET: changed columns replace the all-columns guess ----

  def test_relative_set_reorder_skips_membership_pages
    Item.create!(title: "a", position: 1)
    Item.create!(title: "b", position: 2)
    get "/census/kept_count"
    stream = response.headers["X-Upkeep-Stream"]

    # The sprint-reorder shape: position is disjoint from the page's
    # membership predicate (discarded_at) — no refresh.
    Item.where("position >= ?", 1).update_all("position = position + 1")
    assert_no_refresh(stream)
  end

  def test_raw_set_touching_predicate_columns_still_refreshes
    Item.create!(title: "a", position: 1)
    get "/census/kept_count"
    stream = response.headers["X-Upkeep-Stream"]

    Item.update_all("discarded_at = CURRENT_TIMESTAMP")
    assert_refreshes(stream, 1)
  end

  def test_unparseable_set_falls_back_to_all_columns
    item = Item.create!(title: "a", position: 1)
    get "/census/kept_count"
    stream = response.headers["X-Upkeep-Stream"]

    # A hash update_all to position would be skippable; prove the raw-SET
    # parse fallback (nil columns) stays conservative by checking the fact
    # shape directly.
    columns = Item.all.send(:_upkeep_set_columns, "position = position + WHERE nonsense")
    assert_nil columns, "an unparseable SET must mean all columns"
    assert item
    assert stream
  end

  # -- 3. string joins resolve to physical tables --------------------------

  def test_aliased_subquery_join_attributes_the_joined_table
    Item.create!(title: "reviewed", position: 1)
    get "/census/reviewed_items"
    stream = response.headers["X-Upkeep-Stream"]
    tables = Upkeep::Capture.last_recording.read_set.tables

    assert_includes tables.keys, "reviews",
      "the subquery's physical table must be a dependency under its real name"
    refute_includes tables.keys, "__unknown_join__",
      "no unknown-join degrade for a parseable string join"

    # And it behaves like a dependency: a review write refreshes the page.
    Review.create!(item_id: Item.first.id, score: 5)
    assert_refreshes(stream, 1)
  end

  def test_unparseable_string_join_keeps_the_unknown_degrade
    rel = Item.joins("JOIN ((( nonsense")
    rs = Upkeep::ReadSet.new
    recording = Upkeep::Recording.new
    recording.instance_variable_set(:@read_set, rs)
    Upkeep::RelationAnalysis.new(rel).apply_to(recording)
    assert_includes rs.tables.keys, "__unknown_join__",
      "an unparseable join must keep today's conservative marker"
  end

  # -- 5. temporal-literal expiry ------------------------------------------

  def test_today_baked_predicate_stamps_cohort_expiry
    day = Time.new(2026, 8, 6, 14, 0, 0)
    Upkeep.clock = -> { day }
    Assignment.create!(title: "Todayish", start_date: "2026-08-01")

    get "/census/due_today"
    stream = response.headers["X-Upkeep-Stream"]
    cohort = Upkeep.store.expire_due!(Time.new(2026, 8, 7, 0, 0, 1)).first
    assert cohort, "the cohort must expire at the next local-date rollover"
    assert_equal stream, cohort.stream
    assert_equal Date.new(2026, 8, 7).to_time, cohort.expires_at
  end

  def test_expiry_fires_event_and_schedules_refresh
    day = Time.new(2026, 8, 6, 14, 0, 0)
    Upkeep.clock = -> { day }
    get "/census/due_today"
    stream = response.headers["X-Upkeep-Stream"]

    events = []
    sub = ActiveSupport::Notifications.subscribe("cohort_temporal_expiry.upkeep") do |*args|
      events << args.last
    end
    Upkeep.clock = -> { Time.new(2026, 8, 7, 0, 0, 1) }
    expired = Upkeep::TemporalExpiry.fire_due!
    assert_equal [stream], expired.map(&:stream)
    assert_equal 1, events.size
    assert_equal stream, events.first[:stream]
    assert_refreshes(stream, 1)

    # One-shot: firing again finds nothing.
    assert_empty Upkeep::TemporalExpiry.fire_due!
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # Neighbor: a page whose predicates carry no capture-day literal never
  # expires.
  def test_window_predicate_without_today_never_expires
    Upkeep.clock = -> { Time.new(2026, 8, 6, 14, 0, 0) }
    get "/census/active_assignments", params: { on: "2026-06-15" }
    assert response.headers["X-Upkeep-Stream"]
    assert_empty Upkeep.store.expire_due!(Time.new(2026, 9, 1))
  end

  # -- persistence: fragments survive the ActiveRecord store round trip ----

  def test_fragment_predicates_survive_the_durable_store
    Assignment.create!(title: "Current", start_date: "2026-05-01", end_date: nil)
    ar_store = Upkeep::ActiveRecordStore.new
    Upkeep.store = ar_store

    get "/census/active_assignments", params: { on: "2026-06-15" }
    stream = response.headers["X-Upkeep-Stream"]

    outside = Upkeep::Fact.new(
      table: "assignments", id: 999, kind: :update,
      old_attrs: { "id" => 999, "start_date" => "2026-01-01", "end_date" => "2026-02-01" },
      new_attrs: { "id" => 999, "start_date" => "2026-01-01", "end_date" => "2026-02-01" },
      columns: ["title"]
    )
    assert_empty ar_store.matching_cohorts(outside),
      "a JSON-reloaded fragment must still prove irrelevance"

    entering = Upkeep::Fact.new(
      table: "assignments", id: 1000, kind: :insert,
      new_attrs: { "id" => 1000, "start_date" => "2026-06-01", "end_date" => nil }
    )
    assert_equal [stream], ar_store.matching_cohorts(entering).map(&:stream)
  end
end
