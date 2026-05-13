# frozen_string_literal: true

require "active_record"
require "digest"
require "securerandom"

module Upkeep
  module Subscriptions
    class ActiveRecordStore
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

      class ActiveRegistry
        def initialize
          @mutex = Mutex.new
          @subscriptions = {}
          @reverse_index = ReverseIndex.new
        end

        def register(subscription, entries: nil)
          @mutex.synchronize do
            @subscriptions[subscription.id] = subscription
            if entries
              @reverse_index.index_entries(entries)
            else
              @reverse_index.index(subscription)
            end
          end
        end

        def fetch(id)
          @mutex.synchronize { @subscriptions[id] }
        end

        def subscriptions
          @mutex.synchronize { @subscriptions.values }
        end

        def unregister(ids)
          ids = Array(ids)
          @mutex.synchronize do
            ids.each { |id| @subscriptions.delete(id) }
            rebuild_reverse_index!
          end
        end

        def touch(id, metadata:)
          @mutex.synchronize do
            subscription = @subscriptions[id]
            return unless subscription

            @subscriptions[id] = Subscription.new(
              subscription.id,
              subscription.subscriber_id,
              subscription.recorder,
              subscription.graph,
              subscription.metadata.merge(metadata)
            )
          end
        end

        def entries_for(changes)
          @mutex.synchronize { @reverse_index.entries_for(changes) }
        end

        def reset
          @mutex.synchronize do
            @subscriptions = {}
            @reverse_index = ReverseIndex.new
          end
        end

        def covers?(persistent_count)
          count >= persistent_count
        end

        def count
          @mutex.synchronize { @subscriptions.size }
        end

        def summary
          @mutex.synchronize do
            @reverse_index.summary.merge(subscriptions: @subscriptions.size)
          end
        end

        private

        def rebuild_reverse_index!
          @reverse_index = ReverseIndex.new
          @subscriptions.each_value { |subscription| @reverse_index.index(subscription) }
        end
      end

      class PersistentReverseIndex
        def initialize(reverse_index:, index_record:, active_registry: nil, subscription_count: nil)
          @reverse_index = reverse_index
          @index_record = index_record
          @active_registry = active_registry
          @subscription_count = subscription_count
        end

        def entries_for(changes)
          active_entries = active_registry&.entries_for(changes) || []
          return active_entries if active_registry&.covers?(persistent_subscription_count)

          merge_entries(active_entries, persistent_entries_for(changes))
        end

        def summary
          persistent = persistent_summary
          active = active_registry&.summary || { subscriptions: 0, lookup_keys: 0, entries: 0 }
          mode = active_registry&.covers?(persistent_subscription_count) ? :active : :active_and_persistent
          totals = mode == :active ? active : {
            lookup_keys: active.fetch(:lookup_keys) + persistent.fetch(:lookup_keys),
            entries: active.fetch(:entries) + persistent.fetch(:entries)
          }

          {
            lookup_keys: totals.fetch(:lookup_keys),
            entries: totals.fetch(:entries),
            mode: mode,
            active: active,
            persistent: persistent
          }
        end

        def self.digest(value)
          digest_snapshot(Marshal.dump(value))
        end

        def self.digest_snapshot(snapshot)
          Digest::SHA256.hexdigest(snapshot)
        end

        private

        attr_reader :reverse_index, :index_record, :active_registry, :subscription_count

        def persistent_entries_for(changes)
          lookup_keys = Array(changes).flat_map { |change| reverse_index.lookup_keys_for_change(change) }.uniq
          lookup_keys_by_digest = Hash.new { |hash, digest| hash[digest] = [] }
          lookup_keys.each do |lookup_key|
            lookup_keys_by_digest[self.class.digest(lookup_key)] << lookup_key
          end
          lookup_key_digests = lookup_keys_by_digest.keys

          index_record
            .where(lookup_key_digest: lookup_key_digests)
            .pluck(
              :subscription_id,
              :lookup_key_digest,
              :owner_id_snapshot,
              :dependency_cache_key_snapshot,
              :dependency_snapshot
            )
            .filter_map { |row| entry_for_row(row, lookup_keys_by_digest) }
            .uniq { |entry| [entry.subscription_id, entry.owner_id, entry.dependency_cache_key] }
        end

        def persistent_summary
          {
            lookup_keys: index_record.distinct.count(:lookup_key_digest),
            entries: index_record.count
          }
        end

        def persistent_subscription_count
          subscription_count ? subscription_count.call : 0
        end

        def merge_entries(active_entries, persistent_entries)
          (active_entries + persistent_entries).uniq do |entry|
            [entry.subscription_id, entry.owner_id, entry.dependency_cache_key]
          end
        end

        def entry_for_row(row, lookup_keys_by_digest)
          subscription_id, lookup_key_digest, owner_id_snapshot, dependency_cache_key_snapshot, dependency_snapshot = row
          return unless lookup_keys_by_digest.key?(lookup_key_digest)

          ReverseIndex::Entry.new(
            subscription_id,
            load(owner_id_snapshot),
            load(dependency_cache_key_snapshot),
            load(dependency_snapshot)
          )
        end

        def load(snapshot)
          Marshal.load(snapshot)
        end
      end

      attr_reader :reverse_index

      def initialize(subscription_record: SubscriptionRecord, index_record: IndexEntryRecord)
        @subscription_record = subscription_record
        @index_record = index_record
        @index_builder = ReverseIndex.new
        @active_registry = ActiveRegistry.new
        @reverse_index = PersistentReverseIndex.new(
          reverse_index: @index_builder,
          index_record: index_record,
          active_registry: @active_registry,
          subscription_count: -> { subscription_record.count }
        )
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
        subscription = Subscription.new(
          next_subscription_id,
          subscriber_id,
          recorder,
          recorder.graph,
          metadata
        )

        entries = index_builder.entries_for_subscription(subscription)
        persist_subscription(subscription, entries)
        active_registry.register(subscription, entries: entries)
        subscription
      end

      def shutdown = nil

      def touch(id, now: Time.now)
        metadata = { "last_seen_at" => now.utc.iso8601 }
        subscription_record.where(id: id).find_each do |record|
          record.update_columns(
            metadata: record.metadata.to_h.merge(metadata),
            updated_at: now
          )
        end
        active_registry.touch(id, metadata: metadata)
      end

      def prune_stale!(older_than:)
        stale_ids = subscription_record.where(subscription_record.arel_table[:updated_at].lt(older_than)).pluck(:id)
        return 0 if stale_ids.empty?

        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            index_record.where(subscription_id: stale_ids).delete_all
            subscription_record.where(id: stale_ids).delete_all
          end
        end

        active_registry.unregister(stale_ids)
        stale_ids.size
      end

      def fetch(id)
        active_registry.fetch(id) || fetch_persisted(id)
      end

      def fetch_persisted(id)
        record = subscription_record.find(id)
        subscription = Subscription.from_h(load(record.recorder_snapshot))
        Subscription.new(
          subscription.id,
          subscription.subscriber_id,
          subscription.recorder,
          subscription.graph,
          subscription.metadata.merge(record.metadata.to_h)
        )
      end

      def subscriptions
        return active_registry.subscriptions if active_registry.covers?(subscription_record.count)

        active_subscriptions = active_registry.subscriptions.to_h { |subscription| [subscription.id, subscription] }

        subscription_record.order(:created_at, :id).map { |record| Subscription.from_h(load(record.recorder_snapshot)) }
          .map { |subscription| active_subscriptions.fetch(subscription.id, subscription) }
      end

      def reset
        active_registry.reset
        index_record.delete_all
        subscription_record.delete_all
      end

      def summary
        {
          subscriptions: subscription_record.count,
          active_subscriptions: active_registry.count,
          reverse_index: reverse_index.summary
        }
      end

      private

      attr_reader :subscription_record, :index_record, :index_builder, :active_registry

      def persist_subscription(subscription, entries)
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            persist_subscription_record(subscription)
            index_subscription(subscription, entries)
          end
        end
      end

      def persist_subscription_record(subscription)
        subscription_record.create!(
          id: subscription.id,
          subscriber_id: subscription.subscriber_id,
          metadata: subscription.metadata,
          recorder_snapshot: dump(subscription.to_h)
        )
      end

      def index_subscription(subscription, entries)
        now = Time.now
        rows = entries.flat_map do |entry|
          owner_id_snapshot = dump(entry.owner_id)
          dependency_cache_key_snapshot = dump(entry.dependency_cache_key)
          dependency_snapshot = dump(entry.dependency)

          index_builder.lookup_keys_for_dependency(entry.dependency).map do |lookup_key|
            lookup_key_snapshot = dump(lookup_key)
            {
              subscription_id: subscription.id,
              lookup_key_digest: PersistentReverseIndex.digest_snapshot(lookup_key_snapshot),
              lookup_key_snapshot: lookup_key_snapshot,
              owner_id_snapshot: owner_id_snapshot,
              dependency_cache_key_snapshot: dependency_cache_key_snapshot,
              dependency_snapshot: dependency_snapshot,
              created_at: now,
              updated_at: now
            }
          end
        end

        index_record.insert_all!(rows) if rows.any?
      end

      def next_subscription_id
        "subscription-#{SecureRandom.uuid}"
      end

      def dump(value)
        Marshal.dump(value)
      end

      def load(snapshot)
        Marshal.load(snapshot)
      end
    end
  end
end
