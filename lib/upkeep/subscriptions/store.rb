# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "active_registry"

module Upkeep
  module Subscriptions
    class NotFound < KeyError; end

    Subscription = Data.define(:id, :subscriber_id, :recorder, :graph, :metadata) do
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
    end

    class Store
      attr_reader :reverse_index

      def initialize(reverse_index: ReverseIndex.new)
        @active_registry = ActiveRegistry.new(reverse_index: reverse_index)
        @pending_registry = ActiveRegistry.new
        @pending_index_entries = {}
        @reverse_index = active_registry
        @next_id = 0
      end

      def register(subscriber_id:, recorder:, metadata: {}, entries: nil)
        recorder.flush_pending_dependencies if recorder.respond_to?(:flush_pending_dependencies)
        subscription = Subscription.new(
          next_subscription_id,
          subscriber_id,
          recorder,
          recorder.graph,
          metadata
        )

        pending_registry.register(subscription, entries: entries)
        @pending_index_entries[subscription.id] = entries if entries
        subscription
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
        return true if active_registry.fetch(id)

        subscription = pending_registry.fetch(id)
        return false unless subscription

        entries = @pending_index_entries.delete(id)
        active_registry.register(subscription, entries: entries)
        pending_registry.unregister(id)
        true
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

      def subscriptions
        active_registry.subscriptions + pending_registry.subscriptions
      end

      def reset
        @active_registry = ActiveRegistry.new
        @pending_registry = ActiveRegistry.new
        @pending_index_entries = {}
        @reverse_index = active_registry
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
