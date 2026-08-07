require_relative "test_helper"

# The zero-JS client: stock <turbo-cable-stream-source> elements injected
# into captured responses (signed name = activation token), server-side
# activation flip on first verified subscription, and reconnect resync
# (one refresh pushed when the same cohort stream re-subscribes).
class StreamsTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_capture_injects_signed_stream_sources_for_cohort_and_surfaces
    with_auto_subscribe { get "/pulse/board" }
    assert_response :success
    stream = response.headers["X-Upkeep-Stream"]
    assert stream

    sources = response.body.scan(
      /<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="([^"]+)"><\/turbo-cable-stream-source>/
    ).flatten
    assert sources.any?, "captured page should carry stream source elements"

    verified = sources.map { |s| Turbo.signed_stream_verifier.verified(s) }
    assert_includes verified, stream, "cohort stream must be subscribable via its signed name"
    # Surface streams ride along (the page rendered shared-surface candidates).
    assert verified.any? { |v| v.to_s.start_with?("upkeep:surface:") },
           "surface stream sources should be injected too"
    # All injected names verify — nothing unsigned ships.
    assert verified.all?, "every injected stream name must verify"
  end

  def test_no_injection_without_capture
    post "/login", params: { user_id: @alice.id }
    refute_includes response.body.to_s, "turbo-cable-stream-source"
  end

  def test_first_subscription_activates_then_reconnect_pushes_one_refresh
    get "/boards/#{@board1.id}"
    stream = response.headers["X-Upkeep-Stream"]

    assert_equal :first, Upkeep::Streams.subscribed(stream)
    assert_equal 0, broadcasts(stream).size, "first subscription must not refresh"

    assert_equal :reconnect, Upkeep::Streams.subscribed(stream)
    assert_equal 1, broadcasts(stream).size, "reconnect must push exactly one resync refresh"
    tag = ActiveSupport::JSON.decode(broadcasts(stream).first)
    assert_includes tag, %(action="refresh")
    assert_equal 1, Upkeep.stats[:reconnect_refreshes]
  end

  def test_unknown_and_foreign_streams_are_ignored
    assert_nil Upkeep::Streams.subscribed("upkeep:cohort:deadbeef")
    assert_nil Upkeep::Streams.subscribed("some_other_stream")
    assert_equal 0, all_broadcast_payloads.size
  end

  def test_active_record_store_mark_subscribed_is_atomic_first_then_reconnect
    sim = sim_process
    in_process(sim) do
      get "/boards/#{@board1.id}"
      stream = response.headers["X-Upkeep-Stream"]
      assert_equal :first, sim.store.mark_subscribed(stream)
      assert_equal :reconnect, sim.store.mark_subscribed(stream)
      assert_nil sim.store.mark_subscribed("upkeep:cohort:nope")
    end
  ensure
    Upkeep.store = Upkeep::MemoryStore.new
  end
end
