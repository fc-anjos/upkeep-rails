require_relative "test_helper"

# Adversarial leak-hunting: pages deliberately disguised as shareable.
# Every test also runs the ground-truth sentinel grep over every broadcast.
class LeakTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  # Personalization smuggled through Thread.current, invisible to all choke
  # points. Both viewers carry the SAME banner, so digests agree — the
  # scrubbed render (fresh thread, no smuggled state) must disagree and
  # refuse promotion.
  def test_thread_local_smuggling_is_refused_by_scrubbed_divergence
    a = session_for(@alice, banner: "SENTINEL_BANNER")
    c = session_for(@carol, banner: "SENTINEL_BANNER")
    a.get "/threadlocal"
    stream_a = a.response.headers["X-RefreshSync-Stream"]
    c.get "/threadlocal"

    assert_equal :personal, surface("threadlocal_cards").status
    assert_equal :scrubbed_divergence, surface("threadlocal_cards").pin_reason

    Card.create!(board: @board1, title: "After smuggle", status: "open")
    assert_refreshes(stream_a, 1)
    assert_equal 0, RefreshSync.stats[:surface_broadcasts]
    assert_no_sentinel_broadcast
  end

  # Admin badge, role diversity ON: two same-role viewers are not enough to
  # promote; the first admin visit records divergent evidence and pins.
  def test_admin_badge_never_promotes_with_role_diversity
    a = session_for(@alice)
    b = session_for(@bob)
    a.get "/badge"
    b.get "/badge"
    assert_equal :observing, surface("badge_cards").status, "same-role evidence is insufficient"

    c = session_for(@carol)
    c.get "/badge"
    assert_equal :personal, surface("badge_cards").status
    assert_equal :digest_divergence, surface("badge_cards").pin_reason

    Card.create!(board: @board1, title: "No broadcast", status: "open")
    drain_debounce
    assert_equal 0, RefreshSync.stats[:surface_broadcasts]
    assert_no_sentinel_broadcast
  end

  # Characterize the same page WITHOUT role diversity: promotion succeeds on
  # two same-role viewers. The admin's own first visit then demotes before
  # she ever subscribes — so the failure mode is not a credential leak (the
  # scrubbed render can't render privileged content) but wrong/degraded
  # content for privileged viewers during the window.
  def test_admin_badge_would_promote_without_role_diversity
    RefreshSync.require_role_diversity = false
    a = session_for(@alice)
    b = session_for(@bob)
    a.get "/badge"
    b.get "/badge"
    assert_equal :shared, surface("badge_cards").status,
      "without role diversity, same-role evidence promotes — the leak-shaped window opens here"

    c = session_for(@carol)
    c.get "/badge"
    assert_equal :personal, surface("badge_cards").status,
      "admin's own capture demotes on divergence"
    assert_no_sentinel_broadcast
  end

  # The residual window that runtime evidence CANNOT fully close: all
  # promotion-time viewers render identically (nobody has the beta flag),
  # the flag flips for one subscribed viewer afterwards, and the next write
  # broadcasts content that is wrong for that viewer. The system heals on
  # that viewer's next GET — but the broadcast in between is the window.
  def test_per_user_flag_flip_window_exists_then_heals
    a = session_for(@alice)
    c = session_for(@carol)
    a.get "/vip"
    c.get "/vip"
    assert_equal :shared, surface("vip_cards").status,
      "role diversity satisfied (user+admin) and nobody is beta: promotion is evidence-clean"

    @carol.update!(beta: true) # users write; no cards-surface signal fires

    Card.create!(board: @board1, title: "Window write", status: "open")
    drain_debounce
    assert_equal 1, RefreshSync.stats[:surface_broadcasts],
      "THE WINDOW: a broadcast happened that is wrong for carol (no VIP lane)"
    payload = ActiveSupport::JSON.decode(broadcasts(surface("vip_cards").stream).first)
    refute_includes payload, "VIP LANE", "scrubbed render can never emit privileged content"

    c.get "/vip" # carol's next real render diverges from the broadcast
    assert_equal :personal, surface("vip_cards").status
    assert_equal :post_broadcast_divergence, surface("vip_cards").pin_reason
    stream_a = a.response.headers["X-RefreshSync-Stream"]
    assert_refreshes(stream_a, 1) # demotion converges viewers via refresh
    assert_no_sentinel_broadcast
  end

  # ENV feature flag: same for all viewers in one process, so it promotes —
  # and because Tier S renders fresh at broadcast time, a flag flip is
  # reflected immediately. Deploy-key rotation forces re-earning promotion.
  def test_env_flag_is_fresh_at_broadcast_and_gated_per_deploy
    ENV["PROTO_FLAG"] = "off"
    a = session_for(@alice)
    c = session_for(@carol)
    a.get "/flagged"
    c.get "/flagged"
    assert_equal :shared, surface("flagged_cards").status

    ENV["PROTO_FLAG"] = "on"
    Card.create!(board: @board1, title: "Flagged write", status: "open")
    drain_debounce
    payload = ActiveSupport::JSON.decode(broadcasts(surface("flagged_cards").stream).last)
    assert_includes payload, "NEW LOOK", "broadcast renders current ENV, not stale capture"

    RefreshSync.deploy_key = "deploy-2"
    a2 = session_for(@alice)
    a2.get "/flagged"
    assert_equal :observing, surface("flagged_cards").status, "new deploy re-earns promotion"
  ensure
    ENV.delete("PROTO_FLAG")
  end

  # Personalized page (dashboard): identity-pinned, Tier P only. The user's
  # sentinel name appears in HTTP responses but never in any broadcast.
  def test_personalized_page_sentinels_never_broadcast
    a = session_for(@alice)
    a.get "/dashboard"
    stream_a = a.response.headers["X-RefreshSync-Stream"]
    assert_includes a.response.body, "SENTINEL_USER_ALICE", "page itself is personalized"

    Card.create!(user_id: @alice.id, title: "Mine", status: "open")
    assert_refreshes(stream_a, 1)
    assert_no_sentinel_broadcast
  end
end
