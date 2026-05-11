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

      class PersistentReverseIndex
        def initialize(reverse_index:, index_record:)
          @reverse_index = reverse_index
          @index_record = index_record
        end

        def entries_for(changes)
          lookup_keys = Array(changes).flat_map { |change| reverse_index.lookup_keys_for_change(change) }.uniq
          lookup_key_digests = lookup_keys.map { |lookup_key| self.class.digest(lookup_key) }
          lookup_keys_by_digest = lookup_keys.group_by { |lookup_key| self.class.digest(lookup_key) }

          index_record
            .where(lookup_key_digest: lookup_key_digests)
            .filter_map { |record| entry_for_record(record, lookup_keys_by_digest) }
            .uniq { |entry| [entry.subscription_id, entry.owner_id, entry.dependency_cache_key] }
        end

        def summary
          {
            lookup_keys: index_record.distinct.count(:lookup_key_digest),
            entries: index_record.count
          }
        end

        def self.digest(value)
          Digest::SHA256.hexdigest(Marshal.dump(value))
        end

        private

        attr_reader :reverse_index, :index_record

        def entry_for_record(record, lookup_keys_by_digest)
          lookup_key = load(record.lookup_key_snapshot)
          return unless lookup_keys_by_digest.fetch(record.lookup_key_digest, []).include?(lookup_key)

          ReverseIndex::Entry.new(
            record.subscription_id,
            load(record.owner_id_snapshot),
            load(record.dependency_cache_key_snapshot),
            load(record.dependency_snapshot)
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
        @reverse_index = PersistentReverseIndex.new(reverse_index: @index_builder, index_record: index_record)
      end

      def self.available?
        return false unless ActiveRecord::Base.connected?

        connection = ActiveRecord::Base.connection
        connection.data_source_exists?("upkeep_subscriptions") &&
          connection.data_source_exists?("upkeep_subscription_index_entries")
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
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

        subscription_record.transaction do
          subscription_record.create!(
            id: subscription.id,
            subscriber_id: subscription.subscriber_id,
            metadata: subscription.metadata,
            recorder_snapshot: dump(subscription.to_h)
          )

          index_subscription(subscription)
        end

        subscription
      end

      def fetch(id)
        Subscription.from_h(load(subscription_record.find(id).recorder_snapshot))
      end

      def subscriptions
        subscription_record.order(:created_at, :id).map { |record| Subscription.from_h(load(record.recorder_snapshot)) }
      end

      def reset
        index_record.delete_all
        subscription_record.delete_all
      end

      def summary
        {
          subscriptions: subscription_record.count,
          reverse_index: reverse_index.summary
        }
      end

      private

      attr_reader :subscription_record, :index_record, :index_builder

      def index_subscription(subscription)
        rows = index_builder.entries_for_subscription(subscription).flat_map do |entry|
          index_builder.lookup_keys_for_dependency(entry.dependency).map do |lookup_key|
            {
              subscription_id: subscription.id,
              lookup_key_digest: PersistentReverseIndex.digest(lookup_key),
              lookup_key_snapshot: dump(lookup_key),
              owner_id_snapshot: dump(entry.owner_id),
              dependency_cache_key_snapshot: dump(entry.dependency_cache_key),
              dependency_snapshot: dump(entry.dependency),
              created_at: Time.now,
              updated_at: Time.now
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
