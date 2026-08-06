require_relative "test_helper"

# Baseline-from-capture: each cohort's region-digest baseline is seeded from
# its own capture-time render and advanced per delivery, per cohort. The
# first write after registration therefore broadcasts only the changed
# region, and a cohort holding an older baseline (missed advancement) gets a
# larger — cumulative, full-content, idempotent — diff, never corruption.
class BaselineTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  SURFACE = "pulse_items"

  def setup
    super
    Item.unscoped.delete_all
    @items = (1..5).map { |i| Item.create!(title: "Task #{i}", position: i) }
  end

  def surface_stream = surface(SURFACE).stream

  def decoded(stream)
    broadcasts(stream).map { |p| ActiveSupport::JSON.decode(p) }
  end

  def replaces_on(stream)
    decoded(stream).select { |t| t.include?(%(action="replace")) }
  end

  def wait_for(stream, count: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while broadcasts(stream).size < count &&
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    drain_debounce
  end

  def subscribe
    @alice_sess = session_for(@alice)
    @carol_sess = session_for(@carol)
    @alice_sess.get "/pulse/board"
    @alice_stream = @alice_sess.response.headers["X-Upkeep-Stream"]
    @carol_sess.get "/pulse/board"
    @carol_stream = @carol_sess.response.headers["X-Upkeep-Stream"]
    assert_equal :region_shared, surface(SURFACE).status, "precondition: promoted"
  end

  def test_first_write_after_registration_broadcasts_only_the_changed_region
    subscribe
    regions = surface(SURFACE).region_addresses
    assert_operator regions.size, :>=, 2,
      "fixture must have several regions for the diff to be observable"

    @items.first.update!(title: "Task 1 (first write)")
    wait_for(surface_stream)

    replaces = replaces_on(surface_stream)
    assert_equal 1, replaces.size,
      "first write must NOT send every region — only the changed one: #{replaces.size}"
    assert_includes replaces.first, "Task 1 (first write)"
    untouched = regions.reject { |a| replaces.first.include?(a) }
    assert untouched.any?, "unchanged regions must not be delivered"
    assert_no_sentinel_broadcast
  end

  def test_cohort_with_stale_baseline_gets_cumulative_diff_without_corruption
    subscribe
    carol_cohort = Upkeep.store.cohorts_for_surface(SURFACE)
                              .find { |c| c.stream == @carol_stream }
    capture_baseline = carol_cohort.baselines[SURFACE]

    @items[0].update!(title: "Task 1 (w1)")
    wait_for(surface_stream)
    assert_operator replaces_on(surface_stream).size, :>=, 1, "write 1 delivered"

    # Simulate carol's cohort missing that delivery's baseline advancement
    # (a crash between transport and bookkeeping, a lost message): her
    # server-side baseline reverts to the capture-time one.
    Upkeep.store.update_baseline(@carol_stream, SURFACE, capture_baseline)
    ActionCable.server.pubsub.clear

    @items[1].update!(title: "Task 2 (w2)")
    wait_for(@carol_stream, count: 2)

    alice_replaces = replaces_on(@alice_stream)
    carol_replaces = replaces_on(@carol_stream)
    assert_equal 1, alice_replaces.size, "current cohort gets only the new change"
    assert_includes alice_replaces.first, "Task 2 (w2)"
    assert_equal 2, carol_replaces.size,
      "stale-baseline cohort gets the CUMULATIVE diff: #{carol_replaces.size}"
    assert carol_replaces.any? { |t| t.include?("Task 1 (w1)") },
      "the missed change is re-delivered as full row content"
    assert carol_replaces.any? { |t| t.include?("Task 2 (w2)") }
    assert_equal [], replaces_on(surface_stream),
      "divergent baselines deliver on cohort streams, not the shared stream"
    assert_no_sentinel_broadcast
  end
end
