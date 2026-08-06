require_relative "test_helper"

# Pulse-shaped end-to-end: personalized layout chrome + a per-viewer tag
# INSIDE the shared partial (personal islands), a Discard-scoped ordered
# LIMIT list, a cached aggregate fragment inside the shared region, bulk
# position sweeps, and the full region-broadcast loop.
class PulseFixtureTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def setup
    super
    Item.unscoped.delete_all
    @items = (1..5).map { |i| Item.create!(title: "Task #{i}", position: i) }
    @discarded = Item.create!(title: "Old task", position: 99, discarded_at: Time.now)
  end

  def surface_stream = surface("pulse_items").stream

  def region_broadcasts
    broadcasts(surface_stream).map { |p| ActiveSupport::JSON.decode(p) }
  end

  def subscribe_role_diverse_viewers
    a_sess = session_for(@alice)
    c_sess = session_for(@carol)
    a_sess.get "/pulse/board"
    @alice_trace = Upkeep::Capture.last_recording.prov
    c_sess.get "/pulse/board"
    @carol_trace = Upkeep::Capture.last_recording.prov
    [a_sess.response.headers["X-Upkeep-Stream"],
     c_sess.response.headers["X-Upkeep-Stream"]]
  end

  def test_promotion_localizes_chrome_and_islands_while_list_stays_shared
    subscribe_role_diverse_viewers

    s = surface("pulse_items")
    assert_equal :region_shared, s.status,
      "per-viewer tag inside the partial must yield region promotion, got #{s.status}/#{s.pin_reason}"
    assert s.islands.any?, "the viewer tag must be a recorded island"
    island_texts = s.islands.map { |a| @carol_trace.text_for(a).to_s }
    assert island_texts.any? { |t| t.include?("viewer-tag") },
      "island should be the viewer tag node: #{island_texts.inspect}"
    refute s.region_addresses.include?(s.islands.first),
      "islands are never broadcastable regions"

    list_address = s.region_addresses.find { |a| @carol_trace.text_for(a).to_s.include?(%(id="items")) }
    assert list_address, "the item list must be a broadcastable region: #{s.region_addresses.inspect}"

    # Page-level localization: chrome (who-span, admin nav) diverges; the
    # list is byte-shared between a regular user and an admin.
    localization = Upkeep::Provenance.localize(@alice_trace, @carol_trace)
    chrome_islands = localization[:innermost].map { |a| @carol_trace.text_for(a).to_s }
    assert chrome_islands.any? { |t| t.include?("SENTINEL_USER") || t.include?("Admin tools") },
      "chrome must localize as personal: #{localization[:innermost].inspect}"
    assert_includes localization[:shared], list_address, "the list region is byte-shared"

    # Structural addressing is stamped into the served page — no dom_id.
    assert_includes @carol_trace.text_for(list_address), %(data-rs-node="#{list_address}")
  end

  def test_write_produces_one_scrubbed_render_broadcast_to_all_viewers
    stream_a, stream_c = subscribe_role_diverse_viewers
    b_sess = session_for(@bob)
    b_sess.get "/pulse/board"
    stream_b = b_sess.response.headers["X-Upkeep-Stream"]

    @items.first.update!(title: "Task 1 (renamed)")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while region_broadcasts.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    drain_debounce

    replaces = region_broadcasts.select { |t| t.include?(%(action="replace")) }
    # Baseline-from-capture: the cohorts' baselines were seeded from their
    # own capture-time renders, so even the FIRST write after registration
    # sends only the changed content — here, one row-targeted replace.
    # (Until phase 5 this assertion read "first delivery baselines every
    # region exactly once" — that behavior was removed by design.)
    assert_equal 1, replaces.size,
      "only the changed content is sent on the first write (got #{replaces.size})"
    tag = replaces.first
    assert_includes tag, "Task 1 (renamed)", "the replace carries the write"
    target = tag[/targets="\[data-rs-node=&#39;([^&]*)&#39;\]"/, 1]
    assert target, "replace must target a stamped node address"
    assert_includes target, "@items:", "a one-row change arrives as a row-targeted replace"
    assert_equal replaces.size, Upkeep.stats[:region_broadcasts]

    # Fully covered by the region: nobody gets a refresh; the one broadcast
    # reaches every subscriber via the shared surface stream.
    [stream_a, stream_b, stream_c].each { |s| assert_equal 0, broadcasts(s).size }
    assert_no_sentinel_broadcast
  end

  def test_update_all_position_sweep_is_one_region_broadcast_no_refetch_herd
    stream_a, stream_c = subscribe_role_diverse_viewers

    # The standup moment: a sprint reorder bulk-writes positions while the
    # whole team watches the board.
    Item.unscoped.where(discarded_at: nil).update_all("position = position + 1")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while region_broadcasts.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    drain_debounce

    replaces = region_broadcasts.select { |t| t.include?(%(action="replace")) }
    assert_operator replaces.size, :>=, 1, "the sweep must arrive as region replaces"
    assert replaces.any? { |t| t.include?("(#2)") },
      "region content must carry the swept positions"
    assert_equal 0, broadcasts(stream_a).size, "no per-viewer refetch for a covered bulk write"
    assert_equal 0, broadcasts(stream_c).size
    assert_no_sentinel_broadcast
  end

  def test_partially_covered_write_also_refreshes_the_pinning_cohort
    subscribe_role_diverse_viewers # promotes the surface

    pin_sess = session_for(@bob)
    pin_sess.get "/pulse/board_with_pin", params: { pin: @items.first.id }
    pin_stream = pin_sess.response.headers["X-Upkeep-Stream"]

    @items.first.update!(title: "Task 1 (pinned rename)")
    assert_refreshes(pin_stream, 1) # controller read outside any node -> refresh
    replaces = region_broadcasts.select { |t| t.include?(%(action="replace")) }
    assert_operator replaces.size, :>=, 1, "the region broadcast still goes out"
  end

  def test_discarded_item_writes_are_precisely_ignored
    stream_a, = subscribe_role_diverse_viewers
    @discarded.update!(title: "Old task (edited)")
    drain_debounce
    assert_equal 0, broadcasts(stream_a).size, "kept-scope predicate must exclude discarded rows"
    assert_equal [], region_broadcasts
  end

  def test_cached_fragment_inside_the_region_keeps_dependencies_and_freshness
    subscribe_role_diverse_viewers
    assert_operator Upkeep.stats[:fragment_readset_captures], :>=, 1
    assert_operator Upkeep.stats[:fragment_readset_replays], :>=, 1,
      "the second viewer must hit the fragment and replay its read set"

    # A write that changes the cached aggregate (new top item) still reaches
    # viewers: the fragment key rotates, the region re-renders fresh.
    Item.create!(title: "Task 0", position: 0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while region_broadcasts.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    drain_debounce
    payloads = region_broadcasts.join
    assert_includes payloads, "Task 0", "fresh content must reach subscribers despite the cache"
  end

  def test_uncovered_bulk_write_respects_the_refresh_budget
    Upkeep.debouncer = Upkeep::Debouncer.new(window: WINDOW, refresh_budget: 1)
    streams = [@alice, @bob, @carol].map do |user|
      sess = session_for(user)
      sess.get "/pulse/board_with_pin", params: { pin: @items.first.id }
      sess.response.headers["X-Upkeep-Stream"]
    end

    Item.unscoped.where(discarded_at: nil).update_all("position = position + 1")
    streams.each { |s| assert_refreshes(s, 1) }
    assert_operator Upkeep.stats[:refreshes_deferred], :>=, 1,
      "a table-level burst beyond the budget must defer with jitter"
  end
end
