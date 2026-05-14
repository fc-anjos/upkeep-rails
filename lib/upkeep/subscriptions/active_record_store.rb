# frozen_string_literal: true

require "active_record"
require "active_support/notifications"
require "securerandom"
require_relative "active_record_subscription_persistence"
require_relative "active_registry"
require_relative "async_durable_writer"
require_relative "json_snapshot"
require_relative "layered_reverse_index"
require_relative "persistent_reverse_index"
require_relative "reverse_index"
require_relative "store"

module Upkeep
  module Subscriptions
    class ActiveRecordStore
      LOOKUP_NOTIFICATION = LayeredReverseIndex::LOOKUP_NOTIFICATION
      REGISTER_NOTIFICATION = "register_subscription_store.upkeep"
      PERSIST_NOTIFICATION = ActiveRecordSubscriptionPersistence::PERSIST_NOTIFICATION

      class SubscriptionRecord < ActiveRecord::Base
        self.table_name = "upkeep_subscriptions"
        self.primary_key = "id"

        has_many :index_entries,
          class_name: "Upkeep::Subscriptions::ActiveRecordStore::IndexEntryRecord",
          foreign_key: "subscription_id",
          dependent: :delete_all
      end

      class IndexEntryRecord < ActiveRecord::Base
        self.table_name = "upkeep_subscription_index_entries"

        belongs_to :subscription,
          class_name: "Upkeep::Subscriptions::ActiveRecordStore::SubscriptionRecord",
          foreign_key: "subscription_id"
      end

      attr_reader :reverse_index

      def initialize(subscription_record: SubscriptionRecord, index_record: IndexEntryRecord)
        @subscription_record = subscription_record
        @index_record = index_record
        @index_builder = ReverseIndex.new
        @active_registry = ActiveRegistry.new
        @persistence = ActiveRecordSubscriptionPersistence.new(
          subscription_record: subscription_record,
          index_record: index_record,
          index_builder: index_builder
        )
        persistent_index = PersistentReverseIndex.new(
          reverse_index: index_builder,
          index_record: index_record
        )
        @reverse_index = LayeredReverseIndex.new(
          active_index: active_registry,
          persistent_index: persistent_index,
          persistent_count: -> { persistence.count },
          store: "active_record"
        )
        @durable_writer = AsyncDurableWriter.new { |jobs| persistence.persist_jobs(jobs) }
      end

      def self.available?(connect: false)
        return false unless ActiveRecord::Base.connected? || connect

        connection = ActiveRecord::Base.connection
        connection.data_source_exists?("upkeep_subscriptions") &&
          connection.data_source_exists?("upkeep_subscription_index_entries")
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
        false
      end

      def register(subscriber_id:, recorder:, metadata: {})
        if ActiveSupport::Notifications.notifier.listening?(REGISTER_NOTIFICATION)
          payload = { store: "active_record" }
          ActiveSupport::Notifications.instrument(REGISTER_NOTIFICATION, payload) do
            register_subscription(subscriber_id, recorder, metadata, payload: payload)
          end
        else
          register_subscription(subscriber_id, recorder, metadata)
        end
      end

      def drain = durable_writer.drain

      def shutdown = durable_writer.shutdown

      def touch(id, now: Time.now)
        metadata = { "last_seen_at" => now.utc.iso8601 }
        active_registry.touch(id, metadata: metadata)
        durable_writer.drain
        persistence.touch(id, metadata: metadata, now: now)
      end

      def prune_stale!(older_than:)
        durable_writer.drain
        stale_ids = persistence.prune_stale!(older_than: older_than)
        active_registry.unregister(stale_ids)
        stale_ids.size
      end

      def fetch(id)
        active_registry.fetch(id) || persistence.fetch(id)
      end

      def subscriptions
        persistent_count = persistence.count
        return active_registry.subscriptions if active_registry.covers?(persistent_count)

        active_subscriptions = active_registry.subscriptions.to_h { |subscription| [subscription.id, subscription] }
        persistence.subscriptions.map { |subscription| active_subscriptions.fetch(subscription.id, subscription) }
      end

      def reset
        durable_writer.drain
        active_registry.reset
        persistence.reset
      end

      def summary
        persistent_count = persistence.count
        active_count = active_registry.count
        {
          subscriptions: [persistent_count, active_count].max,
          persistent_subscriptions: persistent_count,
          active_subscriptions: active_count,
          reverse_index: reverse_index.summary
        }
      end

      private

      attr_reader :subscription_record, :index_record, :index_builder, :active_registry, :persistence, :durable_writer

      def register_subscription(subscriber_id, recorder, metadata, payload: nil)
        subscription = Subscription.new(
          next_subscription_id,
          subscriber_id,
          recorder,
          recorder.graph,
          metadata
        )

        entries = unique_entries(index_builder.entries_for_subscription(subscription))
        if payload
          payload[:subscription_id] = subscription.id
          payload[:dependency_entries] = entries.size
          payload[:mode] = "live_first"
          payload[:durability] = "async"
        end

        active_registry.register(subscription, entries: entries)
        durable_writer.enqueue(subscription, entries: entries)
        subscription
      end

      def unique_entries(entries)
        entries.uniq { |entry| [entry.owner_id, entry.dependency_cache_key] }
      end

      def next_subscription_id
        "subscription-#{SecureRandom.uuid}"
      end
    end
  end
end
