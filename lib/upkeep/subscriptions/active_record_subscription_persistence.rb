# frozen_string_literal: true

require "active_record"
require "active_support/notifications"
require "logger"
require_relative "json_snapshot"
require_relative "persistent_reverse_index"
require_relative "store"

module Upkeep
  module Subscriptions
    class ActiveRecordSubscriptionPersistence
      PERSIST_NOTIFICATION = "persist_subscription_store.upkeep"
      INDEX_ENTRIES_SNAPSHOT_KEY = "__upkeep_index_entries"
      Job = Data.define(:subscription, :entries, :operation)

      def initialize(subscription_record:, index_record:, shape_index_record:, index_builder:)
        @subscription_record = subscription_record
        @index_record = index_record
        @shape_index_record = shape_index_record
        @index_builder = index_builder
        @count_mutex = Mutex.new
        @count_cache = nil
      end

      def persist_jobs(jobs)
        if ActiveSupport::Notifications.notifier.listening?(PERSIST_NOTIFICATION)
          payload = {
            store: "active_record",
            jobs: jobs.size,
            subscriptions: jobs.count { |job| persist_subscription?(job) },
            index_jobs: jobs.count { |job| persist_index?(job) },
            dependency_entries: jobs.sum { |job| persist_index?(job) ? job.entries.size : 0 },
            pending_index_entries: jobs.sum { |job| persist_subscription?(job) ? job.entries.size : 0 },
            operations: operation_counts(jobs)
          }
          ActiveSupport::Notifications.instrument(PERSIST_NOTIFICATION, payload) do
            result = persist_jobs_without_instrumentation(jobs)
            payload[:subscription_rows] = result.fetch(:subscription_rows)
            payload[:index_rows] = result.fetch(:index_rows)
            payload[:direct_index_rows] = result.fetch(:direct_index_rows)
            payload[:shape_index_rows] = result.fetch(:shape_index_rows)
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

      def prune_stale!(older_than:, limit: nil)
        stale = subscription_record.where(subscription_record.arel_table[:updated_at].lt(older_than))
        stale = stale.order(:updated_at).limit(limit) if limit
        stale_ids = stale.pluck(:id)
        return [] if stale_ids.empty?

        delete(stale_ids)
        stale_ids
      end

      def delete(ids)
        ids = Array(ids)
        return if ids.empty?

        silence_active_record_logging do
          ActiveRecord::Base.connection_pool.with_connection do
            ActiveRecord::Base.transaction do
              shape_keys = shape_keys_for_subscriptions(ids)
              index_record.where(subscription_id: ids).delete_all
              deleted = subscription_record.where(id: ids).delete_all
              delete_orphaned_shape_index_rows(shape_keys)
              decrement_count_cache(deleted)
            end
          end
        end
      end

      def fetch(id)
        record = subscription_record.find(id)
        subscription_with_metadata(record)
      end

      def fetch_with_index_entries(id)
        record = subscription_record.find(id)
        [subscription_with_metadata(record), index_entries_from_snapshot(record.recorder_snapshot)]
      end

      def subscriptions
        subscription_record.order(:created_at, :id).map { |record| subscription_with_metadata(record) }
      end

      def reset
        index_record.delete_all
        shape_index_record.delete_all
        subscription_record.delete_all
        write_count_cache(0)
      end

      def count
        @count_mutex.synchronize do
          @count_cache ||= subscription_record.count
        end
      end

      private

      attr_reader :subscription_record, :index_record, :shape_index_record, :index_builder

      def persist_jobs_without_instrumentation(jobs)
        subscription_jobs = jobs.select { |job| persist_subscription?(job) }
        index_jobs = jobs.select { |job| persist_index?(job) }

        result = silence_active_record_logging do
          ActiveRecord::Base.connection_pool.with_connection do
            ActiveRecord::Base.transaction do
              subscription_rows = persist_subscription_records(subscription_jobs)
              index_result = index_subscriptions(index_jobs)
              {
                subscription_rows: subscription_rows,
                index_rows: index_result.fetch(:index_rows),
                direct_index_rows: index_result.fetch(:direct_index_rows),
                shape_index_rows: index_result.fetch(:shape_index_rows)
              }
            end
          end
        end
        increment_count_cache(result.fetch(:subscription_rows))
        result
      end

      def persist_subscription_records(jobs)
        now = Time.now
        rows = jobs.map do |job|
          subscription = job.subscription
          {
            id: subscription.id,
            subscriber_id: subscription.subscriber_id,
            metadata: metadata_without_shape_key(subscription.metadata),
            subscription_shape_key: shape_key_for_metadata(subscription.metadata),
            recorder_snapshot: dump(persistent_snapshot_for(job)),
            created_at: now,
            updated_at: now
          }
        end

        subscription_record.insert_all!(rows) if rows.any?
        rows.size
      end

      def index_subscriptions(jobs)
        return index_result if jobs.empty?

        now = Time.now
        subscription_ids = jobs.map { |job| job.subscription.id }.uniq
        shape_jobs, direct_jobs = jobs.partition { |job| shape_indexable?(job) }

        index_record.where(subscription_id: subscription_ids).delete_all

        direct_rows = index_direct_subscriptions(direct_jobs, now: now)
        shape_rows = index_shape_subscriptions(shape_jobs, now: now)
        index_result(direct_index_rows: direct_rows, shape_index_rows: shape_rows)
      end

      def index_direct_subscriptions(jobs, now:)
        return 0 if jobs.empty?

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

      def index_shape_subscriptions(jobs, now:)
        return 0 if jobs.empty?

        grouped_rows = {}
        shape_keys = jobs.map { |job| shape_index_key(job) }.compact.uniq

        jobs.each do |job|
          shape_key = shape_index_key(job)
          job.entries.each do |entry|
            index_builder.lookup_keys_for_dependency(entry.dependency).each do |lookup_key|
              lookup_attributes = typed_lookup_attributes(entry.dependency, lookup_key)
              key = [shape_key, lookup_attributes]
              row = grouped_rows[key] ||= {
                subscription_shape_key: shape_key,
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

        shape_index_record.where(subscription_shape_key: shape_keys).delete_all
        shape_index_record.insert_all!(rows) if rows.any?
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
            dependency_metadata_snapshot: dependency_key[:scope] ? dump(scope: dependency_key[:scope]) : nil
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
        metadata = subscription.metadata.merge(record.metadata.to_h)
        metadata = metadata.merge(subscription_shape_key: record.subscription_shape_key) if record.subscription_shape_key

        Subscription.new(
          subscription.id,
          subscription.subscriber_id,
          subscription.recorder,
          subscription.graph,
          metadata
        )
      end

      def persistent_snapshot_for(job)
        subscription = job.subscription
        subscription.to_persistent_h.merge(
          INDEX_ENTRIES_SNAPSHOT_KEY => index_entries_snapshot(job.entries)
        )
      end

      def index_entries_snapshot(entries)
        entries.map do |entry|
          {
            subscription_id: entry.subscription_id,
            owner_id: entry.owner_id,
            dependency: entry.dependency.to_h
          }
        end
      end

      def index_entries_from_snapshot(recorder_snapshot)
        snapshot = load(recorder_snapshot)
        Array(snapshot.fetch(INDEX_ENTRIES_SNAPSHOT_KEY)).map do |entry_snapshot|
          entry_snapshot = Dependencies.symbolize_keys(entry_snapshot)
          dependency = Dependencies.from_h(entry_snapshot.fetch(:dependency))
          ReverseIndex::Entry.new(
            entry_snapshot.fetch(:subscription_id),
            entry_snapshot.fetch(:owner_id),
            dependency.cache_key,
            dependency,
            nil,
            nil
          )
        end
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

      def shape_keys_for_subscriptions(ids)
        subscription_record.where(id: ids).pluck(:subscription_shape_key).compact.uniq
      end

      def delete_orphaned_shape_index_rows(shape_keys)
        shape_keys.each do |shape_key|
          next if subscription_record.where(subscription_shape_key: shape_key).exists?

          shape_index_record.where(subscription_shape_key: shape_key).delete_all
        end
      end

      def shape_index_key(job)
        shape_key_for_metadata(job.subscription.metadata)
      end

      def shape_indexable?(job)
        shape_index_key(job) && job.entries.any? && job.entries.all?(&:cohort?)
      end

      def index_result(direct_index_rows: 0, shape_index_rows: 0)
        {
          index_rows: direct_index_rows + shape_index_rows,
          direct_index_rows: direct_index_rows,
          shape_index_rows: shape_index_rows
        }
      end

      def shape_key_for_metadata(metadata)
        metadata_value(metadata, :subscription_shape_key)
      end

      def metadata_without_shape_key(metadata)
        metadata.to_h.dup.tap do |attributes|
          attributes.delete(:subscription_shape_key)
          attributes.delete("subscription_shape_key")
        end
      end

      def metadata_value(metadata, key)
        metadata.to_h[key] || metadata.to_h[key.to_s]
      end

      def persist_subscription?(job)
        job.operation == :persist_subscription
      end

      def persist_index?(job)
        job.operation == :persist_index
      end

      def operation_counts(jobs)
        jobs.each_with_object(Hash.new(0)) { |job, counts| counts[job.operation.to_s] += 1 }.to_h
      end

      def silence_active_record_logging
        logger = ActiveRecord::Base.logger
        if logger.respond_to?(:silence)
          logger.silence(::Logger::WARN) { yield }
        else
          yield
        end
      end
    end
  end
end
