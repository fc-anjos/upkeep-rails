# frozen_string_literal: true

module Upkeep
  module Delivery
    class BroadcastTransport
      def initialize(adapter: ActionCableAdapter.new, max_queue_size: 100, retry_limit: 3)
        @adapter = adapter
        @max_queue_size = max_queue_size
        @retry_limit = retry_limit
        @adapter_overrides = {}
        @queue = []
      end

      def connect(subscriber_id:, adapter:)
        adapter_overrides[subscriber_id] = adapter
      end

      def disconnect(subscriber_id)
        adapter_overrides.delete(subscriber_id)
        retained, dropped = queue.partition { |item| item.envelope.subscriber_id != subscriber_id }
        @queue = retained

        Transport::Cleanup.new(subscriber_id, :disconnected, dropped.size)
      end

      def deliver(batch)
        Transport::DispatchReport.new(batch.envelopes.map { |envelope| deliver_envelope(envelope, attempts: 0) })
      end

      def retry_pending(subscriber_id: nil)
        selected, retained = queue.partition do |item|
          subscriber_id.nil? || item.envelope.subscriber_id == subscriber_id
        end
        @queue = retained

        Transport::DispatchReport.new(selected.map { |item| deliver_envelope(item.envelope, attempts: item.attempts) })
      end

      def connected?(subscriber_id)
        adapter_overrides.key?(subscriber_id)
      end

      def summary
        {
          adapter_overrides: adapter_overrides.size,
          queued_envelopes: queue.size,
          max_queue_size: max_queue_size,
          retry_limit: retry_limit
        }
      end

      private

      attr_reader :adapter, :adapter_overrides, :max_queue_size, :retry_limit, :queue

      def deliver_envelope(envelope, attempts:)
        next_attempt = attempts + 1
        adapter_for(envelope.subscriber_id).deliver(envelope)

        outcome(:delivered, envelope, attempts: next_attempt)
      rescue StandardError => error
        if next_attempt >= retry_limit
          outcome(:dropped_retry_exhausted, envelope, attempts: next_attempt, error: error)
        elsif queue.size >= max_queue_size
          outcome(:backpressured, envelope, attempts: next_attempt, error: error)
        else
          queue << Transport::RetryItem.new(envelope, next_attempt, error)
          outcome(:queued_retry, envelope, attempts: next_attempt, error: error)
        end
      end

      def adapter_for(subscriber_id)
        adapter_overrides.fetch(subscriber_id, adapter)
      end

      def outcome(status, envelope, attempts:, error: nil)
        Transport::Outcome.new(
          envelope.subscriber_id,
          status,
          attempts,
          queue.size,
          Transport.envelope_digest(envelope),
          error&.class&.name,
          error&.message
        )
      end
    end
  end
end
