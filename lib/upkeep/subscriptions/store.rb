# frozen_string_literal: true

module Upkeep
  module Subscriptions
    Subscription = Data.define(:id, :subscriber_id, :recorder, :graph, :metadata) do
      def identity_signature(frame_id)
        recorder.identity_signature(frame_id)
      end

      def replay_recipe(frame_id)
        graph.node(frame_id).payload[:recipe]
      end
    end

    class Store
      attr_reader :reverse_index

      def initialize(reverse_index: ReverseIndex.new)
        @reverse_index = reverse_index
        @subscriptions = {}
        @next_id = 0
      end

      def register(subscriber_id:, recorder:, metadata: {})
        subscription = Subscription.new(
          next_subscription_id,
          subscriber_id,
          recorder,
          recorder.graph,
          metadata
        )

        @subscriptions[subscription.id] = subscription
        reverse_index.index(subscription)
        subscription
      end

      def fetch(id)
        @subscriptions.fetch(id)
      end

      def subscriptions
        @subscriptions.values
      end

      def summary
        {
          subscriptions: subscriptions.size,
          reverse_index: reverse_index.summary
        }
      end

      private

      def next_subscription_id
        @next_id += 1
        "subscription-#{@next_id}"
      end
    end
  end
end
