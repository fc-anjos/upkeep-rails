require_relative "test_helper"

# Transport payload limits (Postgres LISTEN/NOTIFY caps at 8KB): an
# oversized Tier S payload degrades THAT delivery to a refresh, loudly.
class PayloadLimitTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def promote_shared_board
    a_sess = session_for(@alice)
    c_sess = session_for(@carol)
    a_sess.get "/shared_board"
    c_sess.get "/shared_board"
    s = surface("open_cards")
    assert_equal :shared, s.status, "precondition: promoted (#{s.pin_reason})"
    [s, a_sess.response.headers["X-Upkeep-Stream"]]
  end

  def test_oversized_payload_degrades_to_refresh_and_warns
    s, cohort_stream = promote_shared_board
    Upkeep.payload_limit = 64 # far below any rendered partial

    events = []
    callback = ->(*, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(callback, "payload_limit_degrade.upkeep") do
      Card.create!(board: @board1, title: "Oversized trigger", status: "open")
      assert_refreshes(cohort_stream, 1) # degraded delivery arrives as refresh
    end

    assert_equal 0, broadcasts(s.stream).size, "no shared broadcast may exceed the limit"
    assert_equal 1, events.size, "degrade must be loudly instrumented"
    assert_operator events.first[:size], :>, 64
    assert_equal 64, events.first[:limit]
    assert_equal :shared, s.status, "degrade is per-delivery, not a demotion"
    assert_operator Upkeep.stats[:payload_limit_degrades], :>=, 1
  end

  def test_small_payload_broadcasts_normally_under_a_generous_limit
    s, cohort_stream = promote_shared_board
    Upkeep.payload_limit = 64_000

    Card.create!(board: @board1, title: "Fits fine", status: "open")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while broadcasts(s.stream).empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    drain_debounce

    assert_equal 1, broadcasts(s.stream).size, "within the limit -> normal Tier S broadcast"
    assert_equal 0, broadcasts(cohort_stream).size
    assert_equal 0, Upkeep.stats[:payload_limit_degrades]
  end
end
