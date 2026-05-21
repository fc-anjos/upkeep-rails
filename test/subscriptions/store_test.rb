# frozen_string_literal: true

require "test_helper"
require "support/subscription_store_contract"

class SubscriptionStoreTest < Minitest::Test
  include SubscriptionStoreContract

  def test_touch_updates_last_seen_metadata
    subscription = store.register(subscriber_id: "subscriber-a", recorder: Upkeep::Runtime::Recorder.new)
    seen_at = Time.utc(2026, 1, 1, 12, 0, 0)

    store.touch(subscription.id, now: seen_at)

    assert_equal seen_at.iso8601, store.fetch(subscription.id).metadata.fetch("last_seen_at")
  end

  def test_prune_stale_removes_old_subscriptions_from_index
    stale = store.register(subscriber_id: "stale", recorder: recorder_with_dependency)
    fresh = store.register(subscriber_id: "fresh", recorder: recorder_with_dependency)
    store.activate(stale.id)
    store.activate(fresh.id)

    store.touch(stale.id, now: Time.utc(2026, 1, 1))
    store.touch(fresh.id, now: Time.utc(2026, 1, 3))

    pruned = store.prune_stale!(older_than: Time.utc(2026, 1, 2))

    assert_equal 1, pruned
    assert_raises(Upkeep::Subscriptions::NotFound) { store.fetch(stale.id) }
    assert_equal fresh.id, store.fetch(fresh.id).id
    assert_equal 1, store.summary.fetch(:subscriptions)
    assert_equal 1, store.reverse_index.entries_for([change]).size
  end

  def test_unregister_removes_only_selected_subscription_from_index
    removed = store.register(subscriber_id: "removed", recorder: recorder_with_dependency)
    retained = store.register(subscriber_id: "retained", recorder: recorder_with_dependency)
    store.activate(removed.id)
    store.activate(retained.id)

    assert_equal 1, store.unregister(removed.id)

    entries = store.reverse_index.entries_for([change])
    assert_equal [retained.id], entries.map(&:subscription_id)
    assert_raises(Upkeep::Subscriptions::NotFound) { store.fetch(removed.id) }
    assert_equal retained.id, store.fetch(retained.id).id
  end

  def test_nil_id_attribute_dependency_matches_record_changes
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder_with_nil_id_dependency)
    store.activate(subscription.id)

    entries = store.reverse_index.entries_for([change.merge(id: nil)])

    assert_equal [subscription.id], entries.map(&:subscription_id)
  end

  def test_collection_dependency_indexes_proven_columns
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder_with_collection_dependency)
    store.activate(subscription.id)

    status_entries = store.reverse_index.entries_for([change.merge(changed_attributes: ["status"])])
    title_entries = store.reverse_index.entries_for([change.merge(changed_attributes: ["title"])])

    assert_equal [subscription.id], status_entries.map(&:subscription_id)
    assert_empty title_entries
  end

  def test_identity_dependencies_do_not_create_invalidation_index_entries
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder_with_identity_dependency)
    store.activate(subscription.id)

    summary = store.summary.fetch(:reverse_index)

    assert_equal 0, summary.fetch(:lookup_keys)
    assert_equal 0, summary.fetch(:entries)
  end

  private

  def store
    @store ||= Upkeep::Subscriptions::Store.new
  end

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

  def recorder_with_collection_dependency
    recorder = Upkeep::Runtime::Recorder.new
    recorder.record_dependency(
      Upkeep::Dependencies::ActiveRecordCollection.new(
        primary_table: "subscription_store_cards",
        table_columns: { "subscription_store_cards" => ["id", "status"] },
        coverage: :columns,
        sql: "SELECT * FROM subscription_store_cards WHERE status = 'open'"
      )
    )
    recorder
  end

  def recorder_with_nil_id_dependency
    recorder = Upkeep::Runtime::Recorder.new
    recorder.record_dependency(
      Upkeep::Dependencies::ActiveRecordAttribute.new(
        table: "subscription_store_cards",
        model: "SubscriptionStoreCard",
        id: nil,
        attribute: "title"
      )
    )
    recorder
  end

  def recorder_with_identity_dependency
    recorder = Upkeep::Runtime::Recorder.new
    recorder.record_dependency(
      Upkeep::Dependencies::RequestValue.new(key: :path, value: "/cards")
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
