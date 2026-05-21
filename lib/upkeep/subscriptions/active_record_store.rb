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
      ACTIVATE_NOTIFICATION = "activate_subscription_store.upkeep"
      PERSIST_NOTIFICATION = ActiveRecordSubscriptionPersistence::PERSIST_NOTIFICATION
      DURABILITY_MODE = "async_subscription_row_index_on_subscribe"
      INDEX_DURABILITY = "on_subscribe"

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

      DeferredIndexWrite = Data.define(:subscription, :entries)

      def initialize(subscription_record: SubscriptionRecord, index_record: IndexEntryRecord)
        @subscription_record = subscription_record
        @index_record = index_record
        @index_builder = ReverseIndex.new
        @pending_registry = ActiveRegistry.new
        @active_registry = ActiveRegistry.new
        @deferred_index_writes = {}
        @deferred_index_mutex = Mutex.new
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
          store: "active_record",
          pending_index: pending_registry
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

      def register(subscriber_id:, recorder:, metadata: {}, entries: nil)
        if ActiveSupport::Notifications.notifier.listening?(REGISTER_NOTIFICATION)
          payload = { store: "active_record" }
          ActiveSupport::Notifications.instrument(REGISTER_NOTIFICATION, payload) do
            register_subscription(subscriber_id, recorder, metadata, entries: entries, payload: payload)
          end
        else
          register_subscription(subscriber_id, recorder, metadata, entries: entries)
        end
      end

      def drain = durable_writer.drain

      def shutdown
        clear_deferred_index_writes
        durable_writer.shutdown
      end

      def activate(id)
        if ActiveSupport::Notifications.notifier.listening?(ACTIVATE_NOTIFICATION)
          payload = { store: "active_record", subscription_id: id }
          ActiveSupport::Notifications.instrument(ACTIVATE_NOTIFICATION, payload) do
            activate_subscription(id, payload: payload)
          end
        else
          activate_subscription(id)
        end
      end

      def touch(id, now: Time.now)
        metadata = { "last_seen_at" => now.utc.iso8601 }
        pending_registry.touch(id, metadata: metadata)
        active_registry.touch(id, metadata: metadata)
        activate(id)
        durable_writer.drain
        persistence.touch(id, metadata: metadata, now: now)
      end

      def unregister(ids)
        ids = Array(ids)
        pending_registry.unregister(ids)
        active_registry.unregister(ids)
        delete_deferred_index_writes(ids)
        persisted_ids = durable_writer.cancel(ids)
        persistence.delete(persisted_ids)
        ids.size
      end

      def prune_stale!(older_than:)
        durable_writer.drain
        stale_ids = persistence.prune_stale!(older_than: older_than)
        active_registry.unregister(stale_ids)
        stale_ids.size
      end

      def fetch(id)
        active_registry.fetch(id) || pending_registry.fetch(id) || persistence.fetch(id)
      end

      def subscriptions
        persistent_count = persistence.count
        in_memory_subscriptions = (active_registry.subscriptions + pending_registry.subscriptions).to_h do |subscription|
          [subscription.id, subscription]
        end
        return in_memory_subscriptions.values if in_memory_subscriptions.size >= persistent_count

        seen_ids = {}
        persisted = persistence.subscriptions.map do |subscription|
          seen_ids[subscription.id] = true
          in_memory_subscriptions.fetch(subscription.id, subscription)
        end
        persisted + in_memory_subscriptions.values.reject { |subscription| seen_ids[subscription.id] }
      end

      def reset
        clear_deferred_index_writes
        durable_writer.drain
        pending_registry.reset
        active_registry.reset
        persistence.reset
      end

      def summary
        persistent_count = persistence.count
        pending_count = pending_registry.count
        active_count = active_registry.count
        {
          subscriptions: [persistent_count, active_count + pending_count].max,
          persistent_subscriptions: persistent_count,
          pending_subscriptions: pending_count,
          active_subscriptions: active_count,
          deferred_index_subscriptions: deferred_index_count,
          reverse_index: reverse_index.summary
        }
      end

      private

      attr_reader :subscription_record, :index_record, :index_builder, :pending_registry, :active_registry, :persistence, :durable_writer

      def register_subscription(subscriber_id, recorder, metadata, entries: nil, payload: nil)
        recorder.flush_pending_dependencies if recorder.respond_to?(:flush_pending_dependencies)
        subscription = Subscription.new(
          next_subscription_id,
          subscriber_id,
          recorder,
          recorder.graph,
          metadata
        )

        entries = unique_entries(materialize_entries(subscription, entries))
        if payload
          payload[:subscription_id] = subscription.id
          payload[:dependency_entries] = entries.size
          payload[:mode] = "pending_activation"
          payload[:durability] = DURABILITY_MODE
          payload[:index_durability] = INDEX_DURABILITY
        end

        pending_registry.register(subscription, entries: entries)
        durable_writer.enqueue(subscription, entries: entries, operation: :persist_subscription)
        defer_index_write(subscription, entries)
        subscription
      end

      def activate_subscription(id, payload: nil)
        subscription, entries, source = activation_index_write(id)
        unless subscription
          payload[:activated] = false if payload
          payload[:miss_reason] = "no_subscription" if payload
          return false
        end

        unless source == :active
          active_registry.register(subscription, entries: entries)
          pending_registry.unregister(id)
          durable_writer.enqueue(subscription, entries: entries, operation: :persist_index)
        end

        if payload
          payload[:activated] = true
          payload[:activation_source] = source
          payload[:dependency_entries] = entries.size
          payload[:active_subscriptions] = active_registry.count
          payload[:pending_subscriptions] = pending_registry.count
        end

        true
      end

      def defer_index_write(subscription, entries)
        @deferred_index_mutex.synchronize do
          @deferred_index_writes[subscription.id] = DeferredIndexWrite.new(subscription, entries)
        end
      end

      def activation_index_write(id)
        deferred_write = take_deferred_index_write(id)
        if deferred_write
          subscription = pending_registry.fetch(id) || active_registry.fetch(id) || deferred_write.subscription
          return [subscription, deferred_write.entries, :pending]
        end

        if (subscription = active_registry.fetch(id))
          [subscription, [], :active]
        elsif (subscription = pending_registry.fetch(id))
          [subscription, unique_entries(index_builder.entries_for_subscription(subscription)), :pending]
        else
          subscription, entries = persistence.fetch_with_index_entries(id)
          [subscription, entries, :persistent]
        end
      rescue ActiveRecord::RecordNotFound
        [nil, nil, nil]
      end

      def take_deferred_index_write(id)
        @deferred_index_mutex.synchronize { @deferred_index_writes.delete(id) }
      end

      def delete_deferred_index_writes(ids)
        @deferred_index_mutex.synchronize { ids.each { |id| @deferred_index_writes.delete(id) } }
      end

      def clear_deferred_index_writes
        @deferred_index_mutex.synchronize { @deferred_index_writes.clear }
      end

      def deferred_index_count
        @deferred_index_mutex.synchronize { @deferred_index_writes.size }
      end

      def unique_entries(entries)
        entries.uniq { |entry| [entry.owner_id, entry.dependency_cache_key] }
      end

      def materialize_entries(subscription, entries)
        if entries
          index_builder.entries_for_subscription_instance(entries, subscription)
        else
          index_builder.entries_for_subscription(subscription)
        end
      end

      def next_subscription_id
        "subscription-#{SecureRandom.uuid}"
      end
    end
  end
end
