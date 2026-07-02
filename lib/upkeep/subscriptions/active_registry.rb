# frozen_string_literal: true

require_relative "reverse_index"

module Upkeep
  module Subscriptions
    class ActiveRegistry
      def initialize(reverse_index: ReverseIndex.new)
        @mutex = Mutex.new
        @subscriptions = {}
        @reverse_index = reverse_index
      end

      def register(subscription, entries: nil)
        @mutex.synchronize do
          @subscriptions[subscription.id] = subscription
          if entries
            @reverse_index.index_entries(entries, subscription: subscription)
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
          ids.each do |id|
            next unless @subscriptions.delete(id)

            @reverse_index.delete_subscription(id)
          end
        end
      end

      def touch(id, metadata:)
        @mutex.synchronize do
          subscription = @subscriptions[id]
          return false unless subscription

          @subscriptions[id] = subscription.with(metadata: subscription.metadata.merge(metadata))
          true
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
    end
  end
end
