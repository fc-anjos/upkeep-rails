require_relative "test_helper"

# A cache hit must register the same dependencies as a cold render: the
# block's read-set slice is stored beside the fragment and replayed.
class FragmentCacheTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def cards_deps(recording)
    recording.read_set.tables["cards"]
  end

  def test_warm_viewer_registers_identical_dependencies_and_still_refreshes
    # Cold: alice renders the block live.
    a_sess = session_for(@alice)
    a_sess.get "/cached_board/#{@board1.id}"
    stream_a = a_sess.response.headers["X-Upkeep-Stream"]
    cold = cards_deps(Upkeep::Capture.last_recording)
    assert cold, "cold render must record cards dependencies"
    assert_equal 1, Upkeep.stats[:fragment_readset_captures]
    assert_equal 0, Upkeep.stats[:fragment_readset_replays]

    # Warm: bob hits the fragment; the block never runs.
    b_sess = session_for(@bob)
    b_sess.get "/cached_board/#{@board1.id}"
    stream_b = b_sess.response.headers["X-Upkeep-Stream"]
    warm = cards_deps(Upkeep::Capture.last_recording)
    assert_equal 1, Upkeep.stats[:fragment_readset_replays],
      "warm render must replay the stored read set"
    assert warm, "warm render must carry cards dependencies despite the cache hit"
    assert_equal cold.predicates.sort_by(&:to_a), warm.predicates.sort_by(&:to_a),
      "replayed predicates must equal the live-captured ones"
    assert_equal cold.ids.to_a.sort, warm.ids.to_a.sort

    # A write to a card read ONLY inside the cached block reaches both.
    Card.create!(board: @board1, title: "Inside the fragment", status: "open")
    assert_refreshes(stream_a, 1)
    assert_refreshes(stream_b, 1)
  end

  def test_missing_side_entry_expires_the_fragment_and_recaptures
    session_for(@alice).get "/cached_board/#{@board1.id}"
    assert_equal 1, Upkeep.stats[:fragment_readset_captures]

    # Evict ONLY the read-set side entry; the fragment stays warm.
    side_keys = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { side_keys << payload[:key] }, "cache_delete.active_support") do
      Rails.cache.delete_matched(/#{Regexp.escape(Upkeep::FragmentCache::SIDE_KEY_PREFIX)}/)
    end

    c_sess = session_for(@carol)
    c_sess.get "/cached_board/#{@board1.id}"
    stream_c = c_sess.response.headers["X-Upkeep-Stream"]
    assert_equal 2, Upkeep.stats[:fragment_readset_captures],
      "orphaned fragment must be expired and recaptured live"
    assert cards_deps(Upkeep::Capture.last_recording),
      "recaptured render must carry cards dependencies"

    Card.create!(board: @board1, title: "After recapture", status: "open")
    assert_refreshes(stream_c, 1)
  end
end
