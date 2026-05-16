# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class PersistentSubscriptionCard < ActiveRecord::Base
  self.table_name = "persistent_subscription_cards"

  def to_partial_path = "persistent_subscription_cards/card"
end

class PersistentSubscriptionCardsController < ActionController::Base
  def index
    @cards = PersistentSubscriptionCard.where(status: params.fetch(:status, "open")).order(:id)
    render template: "persistent_subscription_cards/index"
  end
end

class ActiveRecordSubscriptionStoreTest < Minitest::Test
  def setup
    @previous_subscription_store = Upkeep::Rails.configuration.subscription_store
    Upkeep::Rails::Install.call
    PersistentSubscriptionCardsController.view_paths = [resolver]

    @database_dir = Dir.mktmpdir("upkeep-active-record-store")
    @stores = []

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(@database_dir, "test.sqlite3"))
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :persistent_subscription_cards, force: true do |table|
        table.string :title, null: false
        table.string :status, null: false
      end

      create_table :upkeep_subscriptions, id: :string, force: true do |table|
        table.string :subscriber_id, null: false
        table.json :recorder_snapshot, null: false
        table.json :metadata
        table.timestamps
      end

      create_table :upkeep_subscription_index_entries, force: true do |table|
        table.string :subscription_id, null: false
        table.string :lookup_key_digest, null: false
        table.string :dependency_source, null: false
        table.string :lookup_table, null: false
        table.json :lookup_record_id_snapshot
        table.string :lookup_attribute, null: false
        table.string :dependency_table, null: false
        table.string :dependency_predicate_digest
        table.json :dependency_metadata_snapshot
        table.json :owner_ids_snapshot, null: false
        table.timestamps
      end

      add_index :upkeep_subscription_index_entries, :lookup_key_digest
      add_index :upkeep_subscription_index_entries, :subscription_id
    end

    Upkeep::Rails.configure do |config|
      config.subscription_store = :active_record
    end
    Upkeep::Runtime::ChangeLog.reset
  end

  def teardown
    @stores&.each(&:shutdown)
    Upkeep::Rails.configure do |config|
      config.subscription_store = @previous_subscription_store
    end
    Upkeep::Rails.reset_runtime!
    FileUtils.rm_rf(@database_dir) if @database_dir
  end

  def test_fetches_rehydrated_subscription_and_plans_through_persisted_reverse_index
    card = PersistentSubscriptionCard.create!(title: "Plan", status: "open")
    PersistentSubscriptionCard.create!(title: "Archived", status: "closed")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    store.activate(subscription.id)
    store.drain

    reloaded_store = active_record_store

    assert_equal 1, reloaded_store.summary.fetch(:subscriptions)
    assert_equal "stream-a", reloaded_store.fetch(subscription.id).metadata.fetch(:stream_name)

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    plan = Upkeep::Invalidation::Planner.new(store: reloaded_store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal ["subscriber-a"], plan.targets.map(&:subscriber_id)
    assert_equal ["fragment"], plan.targets.map { |target| target.target.kind }
    assert_includes plan.targets.first.render, "Plan v2"
    refute_includes plan.targets.first.render, "Archived"
  end

  def test_register_is_pending_until_activation_and_subscription_row_is_durable_before_activation
    card = create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })

    assert_equal "stream-a", store.fetch(subscription.id).metadata.fetch(:stream_name)
    assert_equal 1, store.summary.fetch(:pending_subscriptions)
    assert_equal 0, store.summary.fetch(:active_subscriptions)

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    events = capture_notifications("lookup_subscription_index.upkeep") do
      @pending_entries = store.reverse_index.entries_for(Upkeep::Runtime::ChangeLog.events)
    end

    assert_empty @pending_entries
    assert_equal "pending_activation", events.first.payload.fetch(:mode)
    assert_equal "not_activated_yet", events.first.payload.fetch(:miss_reason)
    assert_operator events.first.payload.fetch(:pending_entries), :>, 0
    assert_equal 0, events.first.payload.fetch(:active_entries)

    store.drain
    reloaded_store = active_record_store

    assert_equal "stream-a", reloaded_store.fetch(subscription.id).metadata.fetch(:stream_name)
    assert_equal 1, Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.count
    assert_equal 0, Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count
    assert_equal 1, store.summary.fetch(:deferred_index_subscriptions)

    store.activate(subscription.id)
    assert_equal 0, store.summary.fetch(:pending_subscriptions)
    assert_equal 1, store.summary.fetch(:active_subscriptions)

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v3")

    events = capture_notifications("lookup_subscription_index.upkeep") do
      @active_entries = store.reverse_index.entries_for(Upkeep::Runtime::ChangeLog.events)
    end

    assert_operator @active_entries.size, :>, 0
    assert_equal "active", events.first.payload.fetch(:mode)
    assert_operator events.first.payload.fetch(:active_entries), :>, 0
    refute_includes events.first.payload, :miss_reason

    store.drain

    assert_operator Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count, :>, 0
    assert_equal 2, Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.first.recorder_snapshot.fetch("__upkeep_snapshot_version")
    assert_equal "active_record_attribute", Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.first.dependency_source
  end

  def test_identity_free_pending_and_active_indexes_share_one_cohort_shape
    card = create_subscription_card!("Plan")
    create_subscription_card!("Build")

    store = active_record_store
    _html, first_recorder = capture_controller_request("/cards?status=open")
    first_subscription = store.register(subscriber_id: "subscriber-a", recorder: first_recorder, metadata: { stream_name: "stream-a", subscription_shape_key: "shape:cards:open" })
    first_pending_entries = store.summary.fetch(:reverse_index).fetch(:pending).fetch(:entries)

    _html, second_recorder = capture_controller_request("/cards?status=open")
    second_subscription = store.register(subscriber_id: "subscriber-b", recorder: second_recorder, metadata: { stream_name: "stream-b", subscription_shape_key: "shape:cards:open" })
    second_pending_entries = store.summary.fetch(:reverse_index).fetch(:pending).fetch(:entries)

    assert_operator first_pending_entries, :>, 0
    assert_equal first_pending_entries, second_pending_entries

    store.activate(first_subscription.id)
    store.activate(second_subscription.id)

    active_entries = store.summary.fetch(:reverse_index).fetch(:active).fetch(:entries)
    assert_equal first_pending_entries, active_entries

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    plan = Upkeep::Invalidation::Planner.new(store: store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal ["subscriber-a", "subscriber-b"], plan.targets.flat_map(&:subscriber_ids).uniq.sort
    assert_equal 2, plan.summary.fetch(:represented_subscribers)
    assert_equal 1, plan.candidate_entries.size
  end

  def test_reloaded_store_can_activate_index_from_persisted_subscription_row
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    store.drain

    reloaded_store = active_record_store
    assert_equal 0, Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count

    assert reloaded_store.activate(subscription.id)
    reloaded_store.drain

    index_rows = Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count
    assert_operator index_rows, :>, 0

    assert reloaded_store.activate(subscription.id)
    reloaded_store.drain

    assert_equal index_rows, Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count
  end

  def test_persisted_subscription_snapshot_keeps_replay_and_identity_without_lifecycle_dependencies
    card = PersistentSubscriptionCard.create!(title: "Plan", status: "open")

    _html, recorder = capture_controller_request("/cards?status=open")
    recorder.record_dependency(
      Upkeep::Dependencies::CurrentAttribute.new(owner: "Current", name: "user", value: "alice")
    )
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    store.activate(subscription.id)
    store.drain

    persisted = Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.find(subscription.id)
    snapshot = Upkeep::Subscriptions::JsonSnapshot.load(persisted.recorder_snapshot)
    graph = Upkeep::Runtime::Recorder.from_h(snapshot.fetch(:recorder)).graph

    refute_empty graph.frame_nodes
    assert graph.dependency_nodes.all? { |node| node.payload.identity? }

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")
    plan = Upkeep::Invalidation::Planner.new(store: active_record_store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal ["subscriber-a"], plan.targets.map(&:subscriber_id)
    assert_includes plan.targets.first.render, "Plan v2"
  end

  def test_register_reports_store_timing_metadata
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    events = capture_notifications("register_subscription_store.upkeep") do
      store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    end

    assert_equal 1, events.size
    assert_equal "active_record", events.first.payload.fetch(:store)
    assert_equal "pending_activation", events.first.payload.fetch(:mode)
    assert_equal "async_subscription_row_index_on_subscribe", events.first.payload.fetch(:durability)
    assert_equal "on_subscribe", events.first.payload.fetch(:index_durability)
    assert_match(/\Asubscription-/, events.first.payload.fetch(:subscription_id))
    assert_operator events.first.payload.fetch(:dependency_entries), :>, 0
    refute_includes events.first.payload, :index_rows
    store.drain
  end

  def test_activate_reports_immediate_active_index_metadata
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })

    events = capture_notifications("activate_subscription_store.upkeep") do
      assert store.activate(subscription.id)
    end

    assert_equal 1, events.size
    assert_equal "active_record", events.first.payload.fetch(:store)
    assert_equal subscription.id, events.first.payload.fetch(:subscription_id)
    assert_equal true, events.first.payload.fetch(:activated)
    assert_equal :pending, events.first.payload.fetch(:activation_source)
    assert_operator events.first.payload.fetch(:dependency_entries), :>, 0
    assert_equal 1, events.first.payload.fetch(:active_subscriptions)
    assert_equal 0, events.first.payload.fetch(:pending_subscriptions)
    store.drain
  end

  def test_register_deduplicates_persistent_index_entries
    recorder = Upkeep::Runtime::Recorder.new
    dependency = Upkeep::Dependencies::ActiveRecordAttribute.new(
      table: "persistent_subscription_cards",
      model: "PersistentSubscriptionCard",
      id: 1,
      attribute: "title"
    )
    2.times { recorder.record_dependency(dependency) }

    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: {})
    store.activate(subscription.id)
    store.drain

    assert_equal 1, Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count
  end

  def test_persistent_lookup_digest_is_stable_after_json_snapshot_round_trip
    lookup_key = [
      :active_record_attribute,
      "persistent_subscription_cards",
      1,
      "title"
    ]
    snapshot = Upkeep::Subscriptions::JsonSnapshot.dump(lookup_key)
    rehydrated_lookup_key = Upkeep::Subscriptions::JsonSnapshot.load(snapshot)

    assert_equal lookup_key, rehydrated_lookup_key
    assert_equal 2, snapshot.fetch("__upkeep_snapshot_version")
    assert_equal(
      Upkeep::Subscriptions::PersistentReverseIndex.digest(lookup_key),
      Upkeep::Subscriptions::PersistentReverseIndex.digest(rehydrated_lookup_key)
    )
  end

  def test_persistent_reverse_index_reports_lookup_mode_and_counts
    card = PersistentSubscriptionCard.create!(title: "Plan", status: "open")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    store.activate(subscription.id)
    store.drain
    reloaded_store = active_record_store

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    events = capture_notifications("lookup_subscription_index.upkeep") do
      reloaded_store.reverse_index.entries_for(Upkeep::Runtime::ChangeLog.events)
    end

    assert_equal 1, events.size
    assert_equal "persistent", events.first.payload.fetch(:mode)
    assert_equal "active_record", events.first.payload.fetch(:store)
    assert_operator events.first.payload.fetch(:persistent_entries), :>, 0
  end

  def test_persist_events_split_subscription_rows_from_index_rows
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = nil

    events = capture_notifications("persist_subscription_store.upkeep") do
      subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
      store.drain
      store.activate(subscription.id)
      store.drain
    end

    assert_equal [1, 0], events.map { |event| event.payload.fetch(:subscription_rows) }
    assert_equal [0, 1], events.map { |event| event.payload.fetch(:index_jobs) }
    assert_equal [0, Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count],
      events.map { |event| event.payload.fetch(:index_rows) }
  end

  def test_touch_updates_persistent_subscription_timestamp
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    seen_at = Time.utc(2026, 1, 1, 12, 0, 0)

    store.touch(subscription.id, now: seen_at)

    assert_equal seen_at.to_i, Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.find(subscription.id).updated_at.to_i
  end

  def test_touch_updates_active_and_persisted_subscription_metadata
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    seen_at = Time.utc(2026, 1, 1, 12, 0, 0)

    store.touch(subscription.id, now: seen_at)

    assert_equal seen_at.iso8601, store.fetch(subscription.id).metadata.fetch("last_seen_at")
    assert_equal seen_at.iso8601, active_record_store.fetch(subscription.id).metadata.fetch("last_seen_at")
  end

  def test_prune_stale_removes_subscription_and_reverse_index_rows
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    stale = store.register(subscriber_id: "stale", recorder: recorder, metadata: { stream_name: "stream-stale" })
    fresh = store.register(subscriber_id: "fresh", recorder: recorder, metadata: { stream_name: "stream-fresh" })

    store.touch(stale.id, now: Time.utc(2026, 1, 1))
    store.touch(fresh.id, now: Time.utc(2026, 1, 3))

    pruned = store.prune_stale!(older_than: Time.utc(2026, 1, 2))

    assert_equal 1, pruned
    assert_raises(ActiveRecord::RecordNotFound) { store.fetch(stale.id) }
    assert_equal fresh.id, store.fetch(fresh.id).id
    assert_equal [fresh.id], Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.pluck(:id)
    assert_equal [fresh.id], Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.distinct.pluck(:subscription_id)
    assert_equal 1, store.summary.fetch(:active_subscriptions)
  end

  def test_unregister_cancels_pending_durable_write
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })

    assert_equal 1, store.unregister(subscription.id)
    store.drain

    assert_equal 0, Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.count
    assert_equal 0, Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count
    assert_raises(ActiveRecord::RecordNotFound) { store.fetch(subscription.id) }
  end

  def test_unregister_deletes_persisted_subscription_and_index_rows
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    store.activate(subscription.id)
    store.drain

    assert_equal 1, store.unregister(subscription.id)

    assert_equal 0, Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.count
    assert_equal 0, Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count
    assert_raises(ActiveRecord::RecordNotFound) { store.fetch(subscription.id) }
  end

  def test_active_registry_covers_planning_when_it_matches_persistent_subscription_count
    card = PersistentSubscriptionCard.create!(title: "Plan", status: "open")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    store.activate(subscription.id)
    store.drain

    Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.delete_all

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    plan = Upkeep::Invalidation::Planner.new(store: store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal :active, store.summary.fetch(:reverse_index).fetch(:mode)
    assert_equal ["subscriber-a"], plan.targets.map(&:subscriber_id)
    assert_equal ["fragment"], plan.targets.map { |target| target.target.kind }
    assert_includes plan.targets.first.render, "Plan v2"
  end

  def test_runtime_uses_configured_active_record_subscription_store
    assert_instance_of Upkeep::Subscriptions::ActiveRecordStore, Upkeep::Rails.subscriptions
  end

  def test_runtime_uses_explicit_memory_subscription_store
    Upkeep::Rails.configure do |config|
      config.subscription_store = :memory
    end

    assert_instance_of Upkeep::Subscriptions::Store, Upkeep::Rails.subscriptions
  end

  def test_active_record_subscription_store_raises_without_tables
    ActiveRecord::Base.connection.drop_table(:upkeep_subscription_index_entries)

    error = assert_raises(Upkeep::Rails::ConfigurationError) do
      Upkeep::Rails.reset_runtime!
    end

    assert_match(/upkeep_subscriptions/, error.message)
  end

  def test_production_rejects_memory_subscription_store
    Upkeep::Rails.configure do |config|
      config.subscription_store = :memory
    end

    error = assert_raises(Upkeep::Rails::ConfigurationError) do
      Upkeep::Rails.validate_configuration!(environment: "production")
    end

    assert_match(/production requires :active_record/, error.message)
  end

  private

  def active_record_store
    store = Upkeep::Subscriptions::ActiveRecordStore.new
    @stores << store
    store
  end

  def create_subscription_card!(title, status: "open")
    PersistentSubscriptionCard.create!(title: title, status: status)
  end

  def capture_controller_request(path)
    result, recorder = Upkeep::Runtime::Observation.capture_request do
      _status, _headers, body = PersistentSubscriptionCardsController.action(:index).call(Rack::MockRequest.env_for(path))
      [collect_body(body), Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def collect_body(body)
    body.each.to_a.join
  ensure
    body.close if body.respond_to?(:close)
  end

  def capture_notifications(name)
    events = []
    subscription = ActiveSupport::Notifications.subscribe(name) { |event| events << event }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def resolver
    ActionView::FixtureResolver.new(
      "persistent_subscription_cards/index.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "persistent_subscription_cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "persistent_subscription_cards/_card.html.erb" => <<~ERB
        <li id="persistent_subscription_card_<%= card.id %>">
          <span class="title"><%= card.title %></span>
          <span class="status"><%= card.status %></span>
        </li>
      ERB
    )
  end
end
