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
    stream_a = a.response.headers["X-Upkeep-Stream"]
    c.get "/threadlocal"

    assert_equal :personal, surface("threadlocal_cards").status
    assert_equal :scrubbed_divergence, surface("threadlocal_cards").pin_reason

    Card.create!(board: @board1, title: "After smuggle", status: "open")
    assert_refreshes(stream_a, 1)
    assert_equal 0, Upkeep.stats[:surface_broadcasts]
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
    assert_equal 0, Upkeep.stats[:surface_broadcasts]
    assert_no_sentinel_broadcast
  end

  # Characterize the same page WITHOUT role diversity: promotion succeeds on
  # two same-role viewers. The admin's own first visit then demotes before
  # she ever subscribes — so the failure mode is not a credential leak (the
  # scrubbed render can't render privileged content) but wrong/degraded
  # content for privileged viewers during the window.
  def test_admin_badge_would_promote_without_role_diversity
    Upkeep.require_role_diversity = false
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

  # The former flag-flip window, now closed by per-member divergence: the
  # flag write matches carol's read set but not the scrub render's, so
  # carol is ejected to personal refresh the moment the flag flips — before
  # any broadcast can be wrong for her — and the surface stays shared for
  # everyone else instead of demoting. (Full walkthrough, including
  # re-admission, in member_divergence_test.rb.)
  def test_per_user_flag_flip_ejects_the_member_not_the_surface
    a = session_for(@alice)
    c = session_for(@carol)
    a.get "/vip"
    c.get "/vip"
    stream_c = c.response.headers["X-Upkeep-Stream"]
    assert_equal :shared, surface("vip_cards").status,
      "role diversity satisfied (user+admin) and nobody is beta: promotion is evidence-clean"

    @carol.update!(beta: true) # write to carol's delta row: ejection signal
    assert_refreshes(stream_c, 1) # carol converges under her own credentials
    assert surface("vip_cards").member_diverged?(@carol.id),
      "the flag write ejects carol from shared delivery"
    assert_equal :shared, surface("vip_cards").status,
      "one member's divergence no longer demotes the surface for everyone"

    Card.create!(board: @board1, title: "Window write", status: "open")
    drain_debounce
    assert_equal 1, Upkeep.stats[:surface_broadcasts]
    payload = ActiveSupport::JSON.decode(broadcasts(surface("vip_cards").stream).first)
    refute_includes payload, "VIP LANE", "scrubbed render can never emit privileged content"
    assert_operator broadcasts(stream_c).size, :>=, 2,
      "the broadcast is chased by a converge refresh for the ejected member"

    c.get "/vip" # carol's own render carries her VIP lane; surface unharmed
    assert_includes c.response.body, "VIP LANE"
    assert_equal :shared, surface("vip_cards").status
    assert surface("vip_cards").member_diverged?(@carol.id), "still personal until digests match"
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

    Upkeep.deploy_key = "deploy-2"
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
    stream_a = a.response.headers["X-Upkeep-Stream"]
    assert_includes a.response.body, "SENTINEL_USER_ALICE", "page itself is personalized"

    Card.create!(user_id: @alice.id, title: "Mine", status: "open")
    assert_refreshes(stream_a, 1)
    assert_no_sentinel_broadcast
  end
end
