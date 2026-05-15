# frozen_string_literal: true

require "securerandom"
require "time"

module Upkeep
  module Subscriptions
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
        @reverse_index = reverse_index
        @subscriptions = {}
        @next_id = 0
      end

      def register(subscriber_id:, recorder:, metadata: {}, entries: nil)
        subscription = Subscription.new(
          next_subscription_id,
          subscriber_id,
          recorder,
          recorder.graph,
          metadata
        )

        @subscriptions[subscription.id] = subscription
        touch(subscription.id)
        if entries
          reverse_index.index_entries(entries, subscription: subscription)
        else
          reverse_index.index(subscription)
        end
        subscription
      end

      def touch(id, now: Time.now)
        subscription = @subscriptions.fetch(id)
        @subscriptions[id] = Subscription.new(
          subscription.id,
          subscription.subscriber_id,
          subscription.recorder,
          subscription.graph,
          subscription.metadata.merge("last_seen_at" => now.utc.iso8601)
        )
      end

      def prune_stale!(older_than:)
        stale_ids = @subscriptions.filter_map do |id, subscription|
          id if last_seen_at(subscription) && last_seen_at(subscription) < older_than
        end

        unregister(stale_ids)
        stale_ids.size
      end

      def unregister(ids)
        ids = Array(ids)
        ids.each do |id|
          next unless @subscriptions.delete(id)

          reverse_index.delete_subscription(id)
        end
        ids.size
      end

      def activate(id)
        @subscriptions.fetch(id)
        true
      end

      def drain
        true
      end

      def shutdown
        true
      end

      def fetch(id)
        @subscriptions.fetch(id)
      end

      def subscriptions
        @subscriptions.values
      end

      def reset
        @subscriptions = {}
        @reverse_index = ReverseIndex.new
        @next_id = 0
      end

      def summary
        {
          subscriptions: subscriptions.size,
          reverse_index: reverse_index.summary
        }
      end

      private

      def next_subscription_id
        "subscription-#{SecureRandom.uuid}"
      end

      def last_seen_at(subscription)
        value = subscription.metadata["last_seen_at"] || subscription.metadata[:last_seen_at]
        Time.parse(value.to_s) if value
      end

      def rebuild_reverse_index!
        @reverse_index = ReverseIndex.new
        subscriptions.each { |subscription| reverse_index.index(subscription) }
      end
    end
  end
end
