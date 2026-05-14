# frozen_string_literal: true

require "active_record"
require "active_support/notifications"
require_relative "json_snapshot"
require_relative "persistent_reverse_index"
require_relative "store"

module Upkeep
  module Subscriptions
    class ActiveRecordSubscriptionPersistence
      PERSIST_NOTIFICATION = "persist_subscription_store.upkeep"

      def initialize(subscription_record:, index_record:, index_builder:)
        @subscription_record = subscription_record
        @index_record = index_record
        @index_builder = index_builder
        @count_mutex = Mutex.new
        @count_cache = nil
      end

      def persist_jobs(jobs)
        if ActiveSupport::Notifications.notifier.listening?(PERSIST_NOTIFICATION)
          payload = {
            store: "active_record",
            subscriptions: jobs.size,
            dependency_entries: jobs.sum { |job| job.entries.size }
          }
          ActiveSupport::Notifications.instrument(PERSIST_NOTIFICATION, payload) do
            payload[:index_rows] = persist_jobs_without_instrumentation(jobs)
          end
        else
          persist_jobs_without_instrumentation(jobs)
        end
      end

      def touch(id, metadata:, now:)
        subscription_record.where(id: id).find_each do |record|
          record.update_columns(
            metadata: record.metadata.to_h.merge(metadata),
            updated_at: now
          )
        end
      end

      def prune_stale!(older_than:)
        stale_ids = subscription_record.where(subscription_record.arel_table[:updated_at].lt(older_than)).pluck(:id)
        return [] if stale_ids.empty?

        delete(stale_ids)
        stale_ids
      end

      def delete(ids)
        ids = Array(ids)
        return if ids.empty?

        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            index_record.where(subscription_id: ids).delete_all
            deleted = subscription_record.where(id: ids).delete_all
            decrement_count_cache(deleted)
          end
        end
      end

      def fetch(id)
        record = subscription_record.find(id)
        subscription_with_metadata(record)
      end

      def subscriptions
        subscription_record.order(:created_at, :id).map { |record| subscription_with_metadata(record) }
      end

      def reset
        index_record.delete_all
        subscription_record.delete_all
        write_count_cache(0)
      end

      def count
        @count_mutex.synchronize do
          @count_cache ||= subscription_record.count
        end
      end

      private

      attr_reader :subscription_record, :index_record, :index_builder

      def persist_jobs_without_instrumentation(jobs)
        index_rows = ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            persist_subscription_records(jobs)
            index_subscriptions(jobs)
          end
        end
        increment_count_cache(jobs.size)
        index_rows
      end

      def persist_subscription_records(jobs)
        now = Time.now
        rows = jobs.map do |job|
          subscription = job.subscription
          {
            id: subscription.id,
            subscriber_id: subscription.subscriber_id,
            metadata: subscription.metadata,
            recorder_snapshot: dump(subscription.to_persistent_h),
            created_at: now,
            updated_at: now
          }
        end

        subscription_record.insert_all!(rows) if rows.any?
      end

      def index_subscriptions(jobs)
        now = Time.now
        grouped_rows = {}

        jobs.each do |job|
          job.entries.each do |entry|
            index_builder.lookup_keys_for_dependency(entry.dependency).each do |lookup_key|
              lookup_attributes = typed_lookup_attributes(entry.dependency, lookup_key)
              key = [job.subscription.id, lookup_attributes]
              row = grouped_rows[key] ||= {
                subscription_id: job.subscription.id,
                lookup_key_digest: PersistentReverseIndex.digest(lookup_key),
                owner_ids: [],
                created_at: now,
                updated_at: now
              }.merge(lookup_attributes)
              row.fetch(:owner_ids) << entry.owner_id
            end
          end
        end

        rows = grouped_rows.values.map do |row|
          row.merge(owner_ids_snapshot: dump(row.delete(:owner_ids).uniq))
        end

        index_record.insert_all!(rows) if rows.any?
        rows.size
      end

      def typed_lookup_attributes(dependency, lookup_key)
        lookup_type = lookup_key.fetch(0)
        source = dependency.source.to_s
        dependency_key = dependency.key

        case lookup_type
        when :active_record_attribute
          _type, table, record_id, attribute = lookup_key
          {
            dependency_source: source,
            lookup_table: table.to_s,
            lookup_record_id_snapshot: dump(record_id),
            lookup_attribute: attribute.to_s,
            dependency_table: dependency_key.fetch(:table).to_s,
            dependency_predicate_digest: nil,
            dependency_metadata_snapshot: nil
          }
        when :active_record_attribute_any_id
          _type, table, attribute = lookup_key
          {
            dependency_source: source,
            lookup_table: table.to_s,
            lookup_record_id_snapshot: nil,
            lookup_attribute: attribute.to_s,
            dependency_table: dependency_key.fetch(:table).to_s,
            dependency_predicate_digest: nil,
            dependency_metadata_snapshot: nil
          }
        when :active_record_collection_column
          _type, table, attribute = lookup_key
          {
            dependency_source: source,
            lookup_table: table.to_s,
            lookup_record_id_snapshot: nil,
            lookup_attribute: attribute.to_s,
            dependency_table: dependency_key.fetch(:table).to_s,
            dependency_predicate_digest: dependency_key.fetch(:predicate_digest).to_s,
            dependency_metadata_snapshot: dump(dependency.metadata)
          }
        else
          raise ArgumentError, "unsupported persistent lookup key: #{lookup_key.inspect}"
        end
      end

      def subscription_with_metadata(record)
        subscription = Subscription.from_h(load(record.recorder_snapshot))
        Subscription.new(
          subscription.id,
          subscription.subscriber_id,
          subscription.recorder,
          subscription.graph,
          subscription.metadata.merge(record.metadata.to_h)
        )
      end

      def dump(value)
        JsonSnapshot.dump(value)
      end

      def load(snapshot)
        JsonSnapshot.load(snapshot)
      end

      def increment_count_cache(value)
        @count_mutex.synchronize { @count_cache += value if @count_cache }
      end

      def decrement_count_cache(value)
        @count_mutex.synchronize { @count_cache -= value if @count_cache }
      end

      def write_count_cache(value)
        @count_mutex.synchronize { @count_cache = value }
      end
    end
  end
end
