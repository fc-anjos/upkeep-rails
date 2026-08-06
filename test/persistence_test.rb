require_relative "test_helper"

# Durable cohorts + cross-process delivery over the shared AR store.
class PersistenceTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_cohorts_survive_a_restart
    in_process(sim_process) do
      visit_board(@board1)
    end
    stream = response.headers["X-Upkeep-Stream"]

    # "Restart": brand-new store/registry/debouncer instances; all previous
    # in-memory state is gone, only the DB rows remain.
    in_process(sim_process) do
      @card1.update!(title: "Post-restart write")
    end
    assert_refreshes(stream, 1)
  end

  def test_write_in_process_a_reaches_cohort_registered_by_process_b
    process_a = sim_process
    process_b = sim_process

    stream = nil
    in_process(process_b) { stream = visit_board(@board1) }
    in_process(process_a) { @card1.update!(title: "Cross-process") }

    assert_refreshes(stream, 1)
  end

  def test_rapid_writes_across_both_processes_coalesce_to_one_refresh
    process_a = sim_process(window: 0.4)
    process_b = sim_process(window: 0.4)

    stream = nil
    in_process(process_b) { stream = visit_board(@board1) }
    in_process(process_a) { @card1.update!(title: "From A") }
    in_process(process_b) { @card1.update!(title: "From B") }

    sleep 1.2
    assert_equal 1, broadcasts(stream).size,
      "both processes dispatched, the claim let exactly one broadcast"
    assert_operator Upkeep.stats[:claims_lost], :>=, 1
  end

  def test_promotion_evidence_accumulates_across_processes_and_demotion_propagates
    process_a = sim_process
    process_b = sim_process

    a_sess = session_for(@alice)
    c_sess = session_for(@carol)
    in_process(process_a) { a_sess.get "/vip" }
    stream_a = a_sess.response.headers["X-Upkeep-Stream"]
    in_process(process_b) { c_sess.get "/vip" }

    in_process(process_a) do
      assert_equal :shared, surface("vip_cards").status,
        "promotion built from evidence contributed by viewers on two processes"
    end

    # Divergence seen by process A demotes for process B.
    @carol.update_columns(beta: true)
    in_process(process_a) { c_sess.get "/vip" }
    in_process(process_b) do
      assert_equal :personal, surface("vip_cards").status
      assert_equal :digest_divergence, surface("vip_cards").pin_reason
    end
    assert_refreshes(stream_a, 1) # demotion converged existing viewers
    assert_no_sentinel_broadcast
  end
end
