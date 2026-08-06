require_relative "test_helper"

# Cohort lifecycle (nothing grows unboundedly) and cross-process surface
# persistence under concurrent mutation (optimistic locking).
class LifecycleTest < ActiveSupport::TestCase
  include ProofHelpers

  def ar_store
    @ar_store ||= RefreshSync::ActiveRecordStore.new
  end

  def register_cohort
    rs = RefreshSync::ReadSet.new
    rs.record_id("cards", @card1.id)
    ar_store.register(read_set: rs)
  end

  def rows = RefreshSync::ActiveRecordStore::CohortRow
  def table_rows = RefreshSync::ActiveRecordStore::CohortTableRow
  def claim_rows = RefreshSync::ActiveRecordStore::ClaimRow

  def test_never_activated_cohorts_are_swept
    cohort = register_cohort
    assert_equal 1, rows.count
    assert_equal 1, table_rows.count

    # Too fresh to sweep.
    ar_store.sweep!
    assert_equal 1, rows.count

    rows.update_all(heartbeat_at: Time.now - RefreshSync::ActiveRecordStore::UNACTIVATED_TTL - 5)
    swept = ar_store.sweep!
    assert_equal 1, swept[:cohorts]
    assert_equal 0, rows.count
    assert_equal 0, table_rows.count, "join rows go with their cohort"
    refute ar_store.watching?("cards"), "swept cohorts stop being watched"
    assert cohort # silence unused warning
  end

  def test_activated_cohorts_survive_on_heartbeat_and_die_without
    cohort = register_cohort
    ar_store.mark_subscribed(cohort.stream)

    rows.update_all(heartbeat_at: Time.now - RefreshSync::ActiveRecordStore::COHORT_TTL - 5)
    ar_store.heartbeat(cohort.stream) # a live subscription touches it
    ar_store.sweep!
    assert_equal 1, rows.count, "heartbeat keeps an activated cohort alive"

    rows.update_all(heartbeat_at: Time.now - RefreshSync::ActiveRecordStore::COHORT_TTL - 5)
    ar_store.sweep!
    assert_equal 0, rows.count, "no heartbeat within the TTL: no browser behind it"
  end

  def test_dead_claims_are_swept
    RefreshSync::DbClaimer.new.call("stream-x", 1)
    claim_rows.update_all(created_at: Time.now - RefreshSync::ActiveRecordStore::CLAIM_TTL - 5)
    swept = ar_store.sweep!
    assert_equal 1, swept[:claims]
    assert_equal 0, claim_rows.count
  end

  def test_concurrent_member_ejections_both_survive
    registry_a = RefreshSync::ActiveRecordSurfaceRegistry.new
    registry_b = RefreshSync::ActiveRecordSurfaceRegistry.new
    seeded = registry_a.upsert("race")
    seeded.instance_variable_set(:@status, :shared)
    seeded.instance_variable_set(:@shared_read_set, RefreshSync::ReadSet.new)
    seeded.persist!

    # Two processes hydrate the same row, then each ejects a different
    # member. Without optimistic locking the second persist clobbers the
    # first ejection (the flagged lost-update).
    surface_a = registry_a.lookup("race")
    surface_b = registry_b.lookup("race")
    surface_a.eject_member!("1", reason: :delta_row_write)
    surface_b.eject_member!("2", reason: :delta_row_write)

    fresh = registry_a.lookup("race")
    assert fresh.member_diverged?("1"), "first ejection lost to a concurrent persist"
    assert fresh.member_diverged?("2")
  end

  def test_registration_sweeps_opportunistically
    register_cohort
    rows.update_all(heartbeat_at: Time.now - RefreshSync::ActiveRecordStore::UNACTIVATED_TTL - 5)
    # Force the interval gate open, then a plain registration triggers it.
    ar_store.instance_variable_set(:@last_sweep_at, 0.0)
    register_cohort
    assert_equal 1, rows.count, "the stale cohort went; the new one stays"
  end
end
