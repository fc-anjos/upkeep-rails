# frozen_string_literal: true

require "securerandom"
require "time"
require "active_support/notifications"
require_relative "active_registry"

module Upkeep
  module Subscriptions
    class NotFound < KeyError; end

    Subscription = Data.define(:id, :subscriber_id, :recorder, :graph, :metadata) do
      def explain
        dependency_nodes = graph.dependency_nodes
        dependencies = dependency_nodes.map(&:payload)

        {
          id: id,
          subscriber_id: subscriber_id,
          tables: active_record_tables(dependencies),
          identity: identity_dependencies(dependencies),
          frame_count: graph.frame_nodes.size,
          dependency_count: dependency_nodes.size,
          lookup_keys: lookup_keys_for(dependencies),
          metadata: explain_metadata
        }
      end

      def identity_signature(frame_id)
        recorder.identity_signature(frame_id)
      end

      def replay_recipe(frame_id)
        graph.node(frame_id).payload[:recipe]
      end

      def to_h
        {
          id: id,
          subscriber_id: subscriber_id,
          recorder: recorder.to_h,
          metadata: metadata
        }
      end

      def to_persistent_h
        {
          id: id,
          subscriber_id: subscriber_id,
          recorder: recorder.to_persistent_h,
          metadata: metadata
        }
      end

      def self.from_h(snapshot)
        snapshot = Dependencies.symbolize_keys(snapshot)
        recorder = Runtime::Recorder.from_h(snapshot.fetch(:recorder))

        new(
          snapshot.fetch(:id),
          snapshot.fetch(:subscriber_id),
          recorder,
          recorder.graph,
          snapshot.fetch(:metadata)
        )
      end

      private

      def active_record_tables(dependencies)
        tables = Hash.new { |hash, table| hash[table] = [] }

        dependencies.each do |dependency|
          case dependency.source
          when :active_record_attribute
            tables[dependency.key.fetch(:table).to_s] << dependency.key.fetch(:attribute).to_s
          when :active_record_collection, :active_record_query
            dependency.metadata.fetch(:table_columns, {}).each do |table, columns|
              tables[table.to_s].concat(Array(columns).map(&:to_s))
            end
          end
        end

        tables.transform_values { |columns| columns.uniq.sort }.sort.to_h
      end

      def identity_dependencies(dependencies)
        dependencies.select(&:identity?).map do |dependency|
          {
            source: dependency.source.to_s,
            key: dependency.key.fetch(:key),
            value: dependency.key.fetch(:value),
            partitioning: Dependencies.partitioning_identity?(dependency)
          }
        end.sort_by(&:inspect)
      end

      def lookup_keys_for(dependencies)
        index = ReverseIndex.new
        dependencies.flat_map { |dependency| index.lookup_keys_for_dependency(dependency) }.uniq.sort_by(&:inspect)
      end

      def explain_metadata
        keys = [
          :path,
          "path",
          :stream_name,
          "stream_name",
          :shared_stream_names,
          "shared_stream_names",
          :identity_mode,
          "identity_mode",
          :identity_sources,
          "identity_sources",
          :identity_names,
          "identity_names",
          :subscription_shape_key,
          "subscription_shape_key"
        ]

        metadata.to_h.select { |key, _value| keys.include?(key) }
      end
    end

    class MemoryReverseIndex
      LOOKUP_NOTIFICATION = "lookup_subscription_index.upkeep"

      def initialize(active_registry:, pending_registry:)
        @active_registry = active_registry
        @pending_registry = pending_registry
      end

      def entries_for(changes)
        if ActiveSupport::Notifications.notifier.listening?(LOOKUP_NOTIFICATION)
          payload = { changes: Array(changes).size, store: "memory" }
          ActiveSupport::Notifications.instrument(LOOKUP_NOTIFICATION, payload) do
            entries_for_with_payload(changes, payload)
          end
        else
          active_registry.entries_for(changes)
        end
      end

      def summary
        active_registry.summary
      end

      private

      attr_reader :active_registry, :pending_registry

      def entries_for_with_payload(changes, payload)
        active_entries = active_registry.entries_for(changes)
        pending_entries = pending_registry.entries_for(changes)

        payload.merge!(
          active_entries: active_entries.size,
          active_subscriptions: active_registry.count,
          pending_entries: pending_entries.size,
          pending_subscriptions: pending_registry.count,
          persistent_entries: 0,
          persistent_direct_index_entries: 0,
          persistent_shape_index_entries: 0,
          persistent_direct_lookup_keys: 0,
          persistent_shape_lookup_keys: 0,
          persistent_shape_keys: 0,
          persistent_shape_subscriptions: 0,
          mode: active_entries.empty? && pending_entries.any? ? "pending_activation" : "active"
        )

        payload[:miss_reason] = active_entries.empty? ? miss_reason(pending_entries) : nil
        payload.delete(:miss_reason) unless payload[:miss_reason]

        active_entries
      end

      def miss_reason(pending_entries)
        pending_entries.any? ? "not_activated_yet" : "no_matching_subscriber"
      end
    end

    class Store
      PERSIST_NOTIFICATION = "persist_subscription_store.upkeep"

      attr_reader :reverse_index

      def initialize(reverse_index: ReverseIndex.new)
        @active_registry = ActiveRegistry.new(reverse_index: reverse_index)
        @pending_registry = ActiveRegistry.new
        @pending_index_entries = {}
        @reverse_index = MemoryReverseIndex.new(active_registry: active_registry, pending_registry: pending_registry)
        @next_id = 0
      end

      def register(subscriber_id:, recorder:, metadata: {}, entries: nil)
        if ActiveSupport::Notifications.notifier.listening?(PERSIST_NOTIFICATION)
          payload = memory_persist_payload(operation: :persist_subscription)
          ActiveSupport::Notifications.instrument(PERSIST_NOTIFICATION, payload) do
            register_subscription(subscriber_id: subscriber_id, recorder: recorder, metadata: metadata, entries: entries, payload: payload)
          end
        else
          register_subscription(subscriber_id: subscriber_id, recorder: recorder, metadata: metadata, entries: entries)
        end
      end

      def touch(id, now: Time.now)
        fetch(id)
        metadata = { "last_seen_at" => now.utc.iso8601 }
        pending_registry.touch(id, metadata: metadata)
        active_registry.touch(id, metadata: metadata)
        true
      end

      def prune_stale!(older_than:)
        stale_ids = subscriptions.filter_map do |subscription|
          id = subscription.id
          id if last_seen_at(subscription) && last_seen_at(subscription) < older_than
        end

        unregister(stale_ids)
        stale_ids.size
      end

      def unregister(ids)
        ids = Array(ids)
        ids.each { |id| @pending_index_entries.delete(id) }
        pending_registry.unregister(ids)
        active_registry.unregister(ids)
        ids.size
      end

      def activate(id)
        if ActiveSupport::Notifications.notifier.listening?(PERSIST_NOTIFICATION)
          payload = memory_persist_payload(operation: :persist_index)
          ActiveSupport::Notifications.instrument(PERSIST_NOTIFICATION, payload) do
            activate_subscription(id, payload: payload)
          end
        else
          activate_subscription(id)
        end
      end

      def drain
        true
      end

      def shutdown
        true
      end

      def fetch(id)
        active_registry.fetch(id) || pending_registry.fetch(id) || raise(NotFound, id)
      end

      def explain(id)
        fetch(id).explain
      end

      def subscriptions
        active_registry.subscriptions + pending_registry.subscriptions
      end

      def reset
        @active_registry = ActiveRegistry.new
        @pending_registry = ActiveRegistry.new
        @pending_index_entries = {}
        @reverse_index = MemoryReverseIndex.new(active_registry: active_registry, pending_registry: pending_registry)
        @next_id = 0
      end

      def summary
        active = active_registry.summary
        pending = pending_registry.summary
        {
          subscriptions: subscriptions.size,
          pending_subscriptions: pending_registry.count,
          active_subscriptions: active_registry.count,
          deferred_index_subscriptions: 0,
          reverse_index: active.merge(
            mode: :active,
            active: active,
            pending: pending,
            persistent: { lookup_keys: 0, entries: 0 }
          )
        }
      end

      private

      attr_reader :pending_registry, :active_registry

      def register_subscription(subscriber_id:, recorder:, metadata: {}, entries: nil, payload: nil)
        recorder.flush_pending_dependencies if recorder.respond_to?(:flush_pending_dependencies)
        subscription = Subscription.new(
          next_subscription_id,
          subscriber_id,
          recorder,
          recorder.graph,
          metadata
        )

        if payload
          entry_count = dependency_entry_count(subscription, entries)
          payload[:pending_index_entries] = entry_count
          payload[:subscription_rows] = 1
          payload[:index_rows] = 0
          payload[:direct_index_rows] = 0
          payload[:shape_index_rows] = 0
        end

        pending_registry.register(subscription, entries: entries)
        @pending_index_entries[subscription.id] = entries if entries
        subscription
      end

      def activate_subscription(id, payload: nil)
        if active_registry.fetch(id)
          payload.merge!(subscription_rows: 0, index_rows: 0, direct_index_rows: 0, shape_index_rows: 0) if payload
          return true
        end

        subscription = pending_registry.fetch(id)
        unless subscription
          payload.merge!(subscription_rows: 0, index_rows: 0, direct_index_rows: 0, shape_index_rows: 0) if payload
          return false
        end

        entries = @pending_index_entries.delete(id)
        if payload
          entry_count = dependency_entry_count(subscription, entries)
          payload[:dependency_entries] = entry_count
          payload[:subscription_rows] = 0
          payload[:index_rows] = entry_count
          payload[:direct_index_rows] = entry_count
          payload[:shape_index_rows] = 0
        end

        active_registry.register(subscription, entries: entries)
        pending_registry.unregister(id)
        true
      end

      def memory_persist_payload(operation:)
        {
          store: "memory",
          jobs: 1,
          subscriptions: operation == :persist_subscription ? 1 : 0,
          index_jobs: operation == :persist_index ? 1 : 0,
          dependency_entries: 0,
          pending_index_entries: 0,
          operations: { operation.to_s => 1 }
        }
      end

      def dependency_entry_count(subscription, entries)
        index = ReverseIndex.new
        materialized = if entries
          index.entries_for_subscription_instance(entries, subscription)
        else
          index.entries_for_subscription(subscription)
        end
        materialized.uniq { |entry| [entry.owner_id, entry.dependency_cache_key] }.size
      end

      def last_seen_at(subscription)
        value = subscription.metadata["last_seen_at"] || subscription.metadata[:last_seen_at]
        Time.parse(value.to_s) if value
      end

      def next_subscription_id
        "subscription-#{SecureRandom.uuid}"
      end
    end
  end
end
