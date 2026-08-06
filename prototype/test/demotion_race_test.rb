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
end
