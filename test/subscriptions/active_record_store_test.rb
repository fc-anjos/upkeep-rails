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
        table.binary :recorder_snapshot, null: false
        table.json :metadata
        table.timestamps
      end

      create_table :upkeep_subscription_index_entries, force: true do |table|
        table.string :subscription_id, null: false
        table.string :lookup_key_digest, null: false
        table.binary :lookup_key_snapshot, null: false
        table.binary :owner_id_snapshot, null: false
        table.binary :dependency_cache_key_snapshot, null: false
        table.binary :dependency_snapshot, null: false
        table.timestamps
      end

      add_index :upkeep_subscription_index_entries, :lookup_key_digest
      add_index :upkeep_subscription_index_entries, :subscription_id
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def teardown
    @stores&.each(&:shutdown)
    FileUtils.rm_rf(@database_dir) if @database_dir
  end

  def test_fetches_rehydrated_subscription_and_plans_through_persisted_reverse_index
    card = PersistentSubscriptionCard.create!(title: "Plan", status: "open")
    PersistentSubscriptionCard.create!(title: "Archived", status: "closed")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })

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

  def test_register_persists_subscription_before_returning
    create_subscription_card!("Plan")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    subscription = store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })
    reloaded_store = active_record_store

    assert_equal "stream-a", store.fetch(subscription.id).metadata.fetch(:stream_name)
    assert_equal "stream-a", reloaded_store.fetch(subscription.id).metadata.fetch(:stream_name)
    assert_operator Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.count, :>, 0
    assert_equal 1, Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord.count
  end

  def test_active_registry_covers_planning_when_it_matches_persistent_subscription_count
    card = PersistentSubscriptionCard.create!(title: "Plan", status: "open")

    _html, recorder = capture_controller_request("/cards?status=open")
    store = active_record_store
    store.register(subscriber_id: "subscriber-a", recorder: recorder, metadata: { stream_name: "stream-a" })

    Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord.delete_all

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    plan = Upkeep::Invalidation::Planner.new(store: store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal :active, store.summary.fetch(:reverse_index).fetch(:mode)
    assert_equal ["subscriber-a"], plan.targets.map(&:subscriber_id)
    assert_equal ["fragment"], plan.targets.map { |target| target.target.kind }
    assert_includes plan.targets.first.render, "Plan v2"
  end

  def test_runtime_promotes_empty_memory_store_when_active_record_tables_are_available
    Upkeep::Rails.instance_variable_set(:@subscriptions, Upkeep::Subscriptions::Store.new)

    assert_instance_of Upkeep::Subscriptions::ActiveRecordStore, Upkeep::Rails.subscriptions
  ensure
    Upkeep::Rails.reset_runtime!
  end

  def test_runtime_keeps_active_memory_store_when_active_record_tables_are_available
    store = Upkeep::Subscriptions::Store.new
    store.register(subscriber_id: "subscriber-a", recorder: Upkeep::Runtime::Recorder.new)
    Upkeep::Rails.instance_variable_set(:@subscriptions, store)

    assert_same store, Upkeep::Rails.subscriptions
  ensure
    Upkeep::Rails.reset_runtime!
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
