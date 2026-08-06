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
    # Freeze the wall clock across both schedules: the claim-window id is
    # computed from it at schedule time, and an uncontrolled clock lets the
    # two writes straddle a window boundary under load (observed flake:
    # 2 broadcasts). Boundary behavior itself is pinned in the test below.
    frozen = Upkeep.now
    Upkeep.clock = -> { frozen }
    in_process(process_a) { @card1.update!(title: "From A") }
    in_process(process_b) { @card1.update!(title: "From B") }
    Upkeep.clock = nil

    sleep 1.2
    assert_equal 1, broadcasts(stream).size,
      "both processes dispatched, the claim let exactly one broadcast"
    assert_operator Upkeep.stats[:claims_lost], :>=, 1
  end

  def test_writes_straddling_a_claim_window_boundary_deliver_separately
    process_a = sim_process(window: 0.4)
    process_b = sim_process(window: 0.4)

    stream = nil
    in_process(process_b) { stream = visit_board(@board1) }
    # Place the two writes in provably different claim windows: each earns
    # its own claim, so two deliveries is the DESIGNED outcome (coalescing
    # only ever collapses work inside one window).
    base = Time.at(((Upkeep.now.to_f / 0.4).floor + 1) * 0.4)
    Upkeep.clock = -> { base }
    in_process(process_a) { @card1.update!(title: "Window N") }
    Upkeep.clock = -> { base + 0.4 }
    in_process(process_b) { @card1.update!(title: "Window N+1") }
    Upkeep.clock = nil

    sleep 1.4
    assert_equal 2, broadcasts(stream).size,
      "different claim windows never coalesce across processes"
  end

  def test_predicate_columns_are_cached_per_table_and_invalidated_by_registration
    store = Upkeep::ActiveRecordStore.new
    read_set = Upkeep::ReadSet.new
    read_set.record_predicate("cards", { "status" => "open" })
    store.register(read_set: read_set)

    assert_includes store.predicate_columns("cards"), "status"

    queries = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries += 1 unless payload[:name] == "SCHEMA"
    end
    begin
      store.predicate_columns("cards")
      assert_equal 0, queries, "second lookup inside the TTL hits the cache"
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # A registration touching the table invalidates immediately (no TTL wait).
    other = Upkeep::ReadSet.new
    other.record_predicate("cards", { "board_id" => 1 })
    store.register(read_set: other)
    assert_includes store.predicate_columns("cards"), "board_id"

    # TTL expiry recomputes: another process's registration (simulated by a
    # second store writing the same tables) becomes visible once the clock
    # passes the horizon.
    foreign = Upkeep::ActiveRecordStore.new
    foreign_set = Upkeep::ReadSet.new
    foreign_set.record_predicate("cards", { "title" => "x" })
    foreign.register(read_set: foreign_set)
    refute_includes store.predicate_columns("cards"), "title",
      "cross-process registration is invisible inside the TTL"
    later = Upkeep.now + Upkeep::ActiveRecordStore::PREDICATE_COLUMNS_TTL + 1
    Upkeep.clock = -> { later }
    assert_includes store.predicate_columns("cards"), "title",
      "TTL expiry picks up the other process's predicates"
  ensure
    Upkeep.clock = nil
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
