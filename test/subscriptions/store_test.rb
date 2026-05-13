# frozen_string_literal: true

require "test_helper"

class SubscriptionStoreTest < Minitest::Test
  def test_touch_updates_last_seen_metadata
    store = Upkeep::Subscriptions::Store.new
    subscription = store.register(subscriber_id: "subscriber-a", recorder: Upkeep::Runtime::Recorder.new)
    seen_at = Time.utc(2026, 1, 1, 12, 0, 0)

    store.touch(subscription.id, now: seen_at)

    assert_equal seen_at.iso8601, store.fetch(subscription.id).metadata.fetch("last_seen_at")
  end

  def test_prune_stale_removes_old_subscriptions_and_rebuilds_index
    store = Upkeep::Subscriptions::Store.new
    stale = store.register(subscriber_id: "stale", recorder: recorder_with_dependency)
    fresh = store.register(subscriber_id: "fresh", recorder: recorder_with_dependency)

    store.touch(stale.id, now: Time.utc(2026, 1, 1))
    store.touch(fresh.id, now: Time.utc(2026, 1, 3))

    pruned = store.prune_stale!(older_than: Time.utc(2026, 1, 2))

    assert_equal 1, pruned
    assert_raises(KeyError) { store.fetch(stale.id) }
    assert_equal fresh.id, store.fetch(fresh.id).id
    assert_equal 1, store.summary.fetch(:subscriptions)
    assert_equal 1, store.reverse_index.entries_for([change]).size
  end

  private

  def recorder_with_dependency
    recorder = Upkeep::Runtime::Recorder.new
    recorder.record_dependency(
      Upkeep::Dependencies::ActiveRecordAttribute.new(
        table: "subscription_store_cards",
        model: "SubscriptionStoreCard",
        id: 1,
        attribute: "title"
      )
    )
    recorder
  end

  def change
    {
      type: "update",
      table: "subscription_store_cards",
      id: 1,
      changed_attributes: ["title"],
      old_values: { "title" => "old" },
      new_values: { "title" => "new" }
    }
  end
end
