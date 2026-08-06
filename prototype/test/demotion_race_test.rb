require_relative "test_helper"

# The cross-process demotion race (HANDOFF.md "Realized while writing this"):
# a scheduled Tier S broadcast closure must not carry a hydrated surface
# whose in-memory status can go stale. Process B schedules a shared
# broadcast; process A demotes before B's window fires; B's dispatch must
# rehydrate and see :personal, not broadcast from the stale :shared copy.
class DemotionRaceTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  RACE_WINDOW = 0.9

  def test_pending_broadcast_in_process_b_is_dropped_when_process_a_demotes
    process_a = sim_process
    process_b = sim_process(window: RACE_WINDOW)

    # Promote vip_cards with role-diverse evidence across both processes.
    a_sess = session_for(@alice)
    c_sess = session_for(@carol)
    in_process(process_a) { a_sess.get "/vip" }
    in_process(process_b) { c_sess.get "/vip" }
    in_process(process_a) do
      assert_equal :shared, surface("vip_cards").status, "precondition: promoted"
    end
    surface_stream = in_process(process_a) { surface("vip_cards").stream }

    # B schedules a Tier S broadcast (due in RACE_WINDOW seconds).
    in_process(process_b) { Card.create!(board: @board1, title: "Pending", status: "open") }
    assert_operator process_b.debouncer.pending_count, :>=, 1,
      "precondition: B holds a pending shared broadcast"

    # A demotes before B's window fires. The write bumped the generation and
    # cleared evidence, so divergence needs two same-generation observations:
    # alice (unchanged) then carol (beta flipped) through process A.
    @carol.update_columns(beta: true) # update_columns: no callbacks, no change event
    in_process(process_a) { a_sess.get "/vip" }
    in_process(process_a) { c_sess.get "/vip" }
    in_process(process_a) do
      assert_equal :personal, surface("vip_cards").status, "precondition: demoted"
    end

    # Let B's dispatcher fire its pending entry.
    sleep RACE_WINDOW + 0.4

    assert_equal [], broadcasts(surface_stream),
      "a shared broadcast fired AFTER demotion (stale closure surface)"
    assert_equal 0, RefreshSync.stats[:surface_broadcasts],
      "no Tier S broadcast may fire once the surface is demoted"
    assert_no_sentinel_broadcast
  end

  # The narrowed window (HANDOFF "Residual"): a demotion that commits AFTER
  # the scrubbed render but BEFORE the transport call. Pre-fix, the final
  # status check was a plain read followed microseconds later by the Turbo
  # call; a demotion landing between them still broadcast. The fix makes the
  # check an atomic store-side compare-and-set on the surface row's status
  # column, so a demotion persisted at any point before the claim wins.
  def test_demotion_landing_between_render_and_transport_is_seen_by_the_store_claim
    process_a = sim_process
    process_b = sim_process(window: RACE_WINDOW)

    a_sess = session_for(@alice)
    c_sess = session_for(@carol)
    in_process(process_a) { a_sess.get "/vip" }
    in_process(process_b) { c_sess.get "/vip" }
    in_process(process_a) do
      assert_equal :shared, surface("vip_cards").status, "precondition: promoted"
    end
    surface_stream = in_process(process_a) { surface("vip_cards").stream }

    # B schedules a Tier S broadcast.
    in_process(process_b) { Card.create!(board: @board1, title: "Pending", status: "open") }
    assert_operator process_b.debouncer.pending_count, :>=, 1,
      "precondition: B holds a pending shared broadcast"

    # The interlock runs on B's dispatcher thread with the scrubbed render
    # already complete, immediately before the dispatch claim — the
    # microsecond window. Process A demotes exactly there.
    dropped = []
    drop_sub = ActiveSupport::Notifications.subscribe("surface_broadcast_dropped.refresh_sync") do |*_a, payload|
      dropped << payload
    end
    interlock_ran = false
    RefreshSync.dispatch_interlock = proc do
      next if interlock_ran
      interlock_ran = true
      stale = process_a.registry.lookup("vip_cards")
      stale.send(:transition_to_personal, :demoted_in_dispatch_window)
      stale.persist!
    end

    sleep RACE_WINDOW + 0.4

    assert interlock_ran, "the dispatch must have reached the pre-transport window"
    assert_equal [], broadcasts(surface_stream),
      "a shared broadcast fired after a demotion inside the dispatch window"
    assert_equal 0, RefreshSync.stats[:surface_broadcasts]
    assert dropped.any? { |p| p[:reason] == :demoted_at_claim },
      "the drop must be loud: #{dropped.inspect}"
    assert_no_sentinel_broadcast
  ensure
    RefreshSync.dispatch_interlock = nil
    ActiveSupport::Notifications.unsubscribe(drop_sub) if drop_sub
  end
end
