# frozen_string_literal: true

module SubscriptionStoreContract
  def test_contract_registered_subscription_is_fetchable
    subscription = store.register(subscriber_id: "contract-subscriber", recorder: recorder_with_dependency)

    assert_equal subscription.id, store.fetch(subscription.id).id
    assert_equal "contract-subscriber", store.fetch(subscription.id).subscriber_id
  end

  def test_contract_activate_returns_true_and_enables_lookup
    subscription = store.register(subscriber_id: "contract-subscriber", recorder: recorder_with_dependency)

    assert_equal true, store.activate(subscription.id)
    store.drain

    assert_equal [subscription.id], store.reverse_index.entries_for([change]).map(&:subscription_id).uniq
  end

  def test_contract_activate_missing_returns_false
    assert_equal false, store.activate("missing-subscription")
  end

  def test_contract_fetch_missing_raises_not_found
    assert_raises(Upkeep::Subscriptions::NotFound) { store.fetch("missing-subscription") }
  end

  def test_contract_touch_updates_liveness_metadata
    subscription = store.register(subscriber_id: "contract-subscriber", recorder: recorder_with_dependency)
    seen_at = Time.utc(2026, 1, 1, 12, 0, 0)

    store.touch(subscription.id, now: seen_at)
    store.drain

    assert_equal seen_at.iso8601, store.fetch(subscription.id).metadata.fetch("last_seen_at")
  end

  def test_contract_touch_missing_raises_not_found
    assert_raises(Upkeep::Subscriptions::NotFound) do
      store.touch("missing-subscription", now: Time.utc(2026, 1, 1))
    end
  end

  def test_contract_unregister_removes_fetchable_subscription
    subscription = store.register(subscriber_id: "contract-subscriber", recorder: recorder_with_dependency)
    store.activate(subscription.id)
    store.drain

    assert_equal 1, store.unregister(subscription.id)
    store.drain

    assert_raises(Upkeep::Subscriptions::NotFound) { store.fetch(subscription.id) }
  end

  def test_contract_prune_removes_touched_stale_subscription
    stale = store.register(subscriber_id: "contract-stale", recorder: recorder_with_dependency)
    fresh = store.register(subscriber_id: "contract-fresh", recorder: recorder_with_dependency)
    store.activate(stale.id)
    store.activate(fresh.id)
    store.touch(stale.id, now: Time.utc(2026, 1, 1))
    store.touch(fresh.id, now: Time.utc(2026, 1, 3))
    store.drain

    assert_equal 1, store.prune_stale!(older_than: Time.utc(2026, 1, 2))

    assert_equal fresh.id, store.fetch(fresh.id).id
    assert_raises(Upkeep::Subscriptions::NotFound) { store.fetch(stale.id) }
  end
end
