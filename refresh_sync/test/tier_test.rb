require_relative "test_helper"

# Two-tier delivery and the promotion state machine.
class TierTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def surface_broadcasts(name)
    broadcasts(surface(name).stream)
  end

  # Genuinely shared page: promoted after two identities with two roles,
  # then one write = ONE shared broadcast, zero cohort refreshes.
  def test_shared_page_promotes_and_broadcasts_once
    a = session_for(@alice)
    c = session_for(@carol)
    a.get "/shared_board"
    stream_a = a.response.headers["X-RefreshSync-Stream"]
    c.get "/shared_board"
    stream_c = c.response.headers["X-RefreshSync-Stream"]

    assert_equal :shared, surface("open_cards").status

    Card.create!(board: @board1, title: "Fresh", status: "open")
    drain_debounce

    assert_equal 1, surface_broadcasts("open_cards").size, "exactly one shared broadcast"
    tag = ActiveSupport::JSON.decode(surface_broadcasts("open_cards").first)
    assert_includes tag, %(action="update")
    assert_includes tag, "Fresh", "broadcast carries the fresh render"
    assert_equal 0, broadcasts(stream_a).size
    assert_equal 0, broadcasts(stream_c).size
    assert_no_sentinel_broadcast
  end

  def test_same_role_viewers_do_not_promote
    a = session_for(@alice)
    b = session_for(@bob)
    a.get "/shared_board"
    stream_a = a.response.headers["X-RefreshSync-Stream"]
    b.get "/shared_board"
    stream_b = b.response.headers["X-RefreshSync-Stream"]

    assert_equal :observing, surface("open_cards").status

    Card.create!(board: @board1, title: "Tier P still", status: "open")
    assert_refreshes(stream_a, 1)
    assert_equal 1, broadcasts(stream_b).size
    assert_equal 0, RefreshSync.stats[:surface_broadcasts]
  end

  def test_unauthenticated_viewers_never_count_as_evidence
    get "/shared_board"
    open_session.get "/shared_board"
    assert_equal :observing, surface("open_cards").status
  end

  def test_identity_predicate_pins_personal
    a = session_for(@alice)
    a.get "/dashboard"
    assert_equal :personal, surface("my_cards").status
    assert_equal :identity_predicate, surface("my_cards").pin_reason
  end

  def test_ambient_session_read_pins_personal
    a = session_for(@alice, tz: "America/Sao_Paulo")
    a.get "/tz"
    assert_equal :personal, surface("tz_cards").status
    assert_equal :ambient_session_read, surface("tz_cards").pin_reason
  end

  # Pinned surfaces stay pinned no matter what evidence arrives later.
  def test_personal_is_terminal
    a = session_for(@alice)
    a.get "/dashboard"
    assert_equal :personal, surface("my_cards").status
    c = session_for(@carol)
    c.get "/dashboard"
    assert_equal :personal, surface("my_cards").status
  end

  # Scrubbed render failure at broadcast time: demote, drop the broadcast,
  # refresh cohorts so viewers still converge.
  def test_render_failure_demotes_and_falls_back_to_refresh
    a = session_for(@alice)
    c = session_for(@carol)
    a.get "/shared_board"
    stream_a = a.response.headers["X-RefreshSync-Stream"]
    c.get "/shared_board"
    assert_equal :shared, surface("open_cards").status

    broken = Class.new(ActionController::Base) # no view paths: render raises
    RefreshSync.renderer_class = broken
    begin
      Card.create!(board: @board1, title: "Boom", status: "open")
      assert_refreshes(stream_a, 1)
      assert_equal :personal, surface("open_cards").status
      assert_match(/scrubbed_render_error/, surface("open_cards").pin_reason.to_s)
      assert_equal 0, RefreshSync.stats[:surface_broadcasts]
    ensure
      RefreshSync.renderer_class = ScrubbedController
    end
  end

  # Promotion state is per deploy key: a new deploy re-earns Tier S.
  def test_promotion_does_not_survive_deploy_key_change
    a = session_for(@alice)
    c = session_for(@carol)
    a.get "/shared_board"
    c.get "/shared_board"
    assert_equal :shared, surface("open_cards").status

    RefreshSync.deploy_key = "deploy-2"
    a2 = session_for(@alice)
    a2.get "/shared_board"
    assert_equal :observing, surface("open_cards").status, "new deploy starts from scratch"
  end

  # A write between two viewers' visits must not read as identity divergence.
  def test_write_between_viewers_does_not_false_pin
    a = session_for(@alice)
    a.get "/shared_board"
    Card.create!(board: @board1, title: "Mid-observation write", status: "open")
    drain_debounce
    c = session_for(@carol)
    c.get "/shared_board"
    assert_equal :observing, surface("open_cards").status,
      "digests across a write are incomparable, not divergent"
    refute_equal :personal, surface("open_cards").status
  end

  # Tier P refresh budget: a table-level write burst to many cohorts is
  # spread across windows instead of stampeding.
  def test_refresh_budget_caps_storms
    RefreshSync.debouncer = RefreshSync::Debouncer.new(window: 0.25, refresh_budget: 8, jitter: 0.3)
    streams = 24.times.map do
      s = open_session
      s.get "/cards"
      s.response.headers["X-RefreshSync-Stream"]
    end

    Card.where(board_id: @board1.id).update_all(status: "swept")

    sleep 0.40 # one window + a little: first tick only
    first_wave = streams.count { |s| broadcasts(s).size == 1 }
    assert_operator first_wave, :<=, 8, "first tick must respect the refresh budget"

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until streams.all? { |s| broadcasts(s).size == 1 } ||
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    assert streams.all? { |s| broadcasts(s).size == 1 }, "every cohort eventually refreshes exactly once"
    assert_operator RefreshSync.stats[:refreshes_deferred], :>, 0
  end
end
