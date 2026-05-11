# frozen_string_literal: true

require "digest"

module Upkeep
  module Delivery
    class Transport
      Outcome = Data.define(
        :subscriber_id,
        :status,
        :attempts,
        :queue_depth,
        :envelope_digest,
        :error_class,
        :error_message
      ) do
        def delivered?
          status == :delivered
        end

        def report
          {
            subscriber_id: subscriber_id,
            status: status,
            attempts: attempts,
            queue_depth: queue_depth,
            envelope_digest: envelope_digest,
            error_class: error_class,
            error_message: error_message
          }.compact
        end
      end

      DispatchReport = Data.define(:outcomes) do
        def summary
          outcomes.each_with_object(Hash.new(0)) { |outcome, counts| counts[outcome.status] += 1 }
        end

        def report
          {
            summary: summary,
            outcomes: outcomes.map(&:report)
          }
        end
      end

      Cleanup = Data.define(:subscriber_id, :status, :dropped_envelopes)
      RetryItem = Data.define(:envelope, :attempts, :error)

      class Connection
        attr_reader :subscriber_id

        def initialize(subscriber_id:, adapter:, max_queue_size:, retry_limit:)
          @subscriber_id = subscriber_id
          @adapter = adapter
          @max_queue_size = max_queue_size
          @retry_limit = retry_limit
          @queue = []
        end

        def deliver(envelope)
          deliver_envelope(envelope, attempts: 0)
        end

        def retry_pending
          pending = @queue
          @queue = []

          pending.map { |item| deliver_envelope(item.envelope, attempts: item.attempts) }
        end

        def disconnect
          dropped = @queue.size
          @queue = []
          dropped
        end

        def queue_depth
          @queue.size
        end

        private

        attr_reader :adapter, :max_queue_size, :retry_limit

        def deliver_envelope(envelope, attempts:)
          next_attempt = attempts + 1
          adapter.deliver(envelope)

          outcome(:delivered, envelope, attempts: next_attempt)
        rescue StandardError => error
          if next_attempt >= retry_limit
            outcome(:dropped_retry_exhausted, envelope, attempts: next_attempt, error: error)
          elsif queue_depth >= max_queue_size
            outcome(:backpressured, envelope, attempts: next_attempt, error: error)
          else
            @queue << RetryItem.new(envelope, next_attempt, error)
            outcome(:queued_retry, envelope, attempts: next_attempt, error: error)
          end
        end

        def outcome(status, envelope, attempts:, error: nil)
          Outcome.new(
            subscriber_id,
            status,
            attempts,
            queue_depth,
            Transport.envelope_digest(envelope),
            error&.class&.name,
            error&.message
          )
        end
      end

      class << self
        def envelope_digest(envelope)
          Digest::SHA256.hexdigest(envelope.body)
        end
      end

      def initialize(max_queue_size: 100, retry_limit: 3)
        @max_queue_size = max_queue_size
        @retry_limit = retry_limit
        @connections = {}
      end

      def connect(subscriber_id:, adapter:)
        Connection.new(
          subscriber_id: subscriber_id,
          adapter: adapter,
          max_queue_size: max_queue_size,
          retry_limit: retry_limit
        ).tap { |connection| connections[subscriber_id] = connection }
      end

      def disconnect(subscriber_id)
        connection = connections.delete(subscriber_id)
        dropped = connection&.disconnect || 0

        Cleanup.new(subscriber_id, :disconnected, dropped)
      end

      def deliver(batch)
        DispatchReport.new(batch.envelopes.map { |envelope| deliver_envelope(envelope) })
      end

      def retry_pending(subscriber_id: nil)
        selected_connections = if subscriber_id
          Array(connections[subscriber_id])
        else
          connections.values
        end

        DispatchReport.new(selected_connections.flat_map(&:retry_pending))
      end

      def connected?(subscriber_id)
        connections.key?(subscriber_id)
      end

      def summary
        {
          connections: connections.size,
          queued_envelopes: connections.values.sum(&:queue_depth),
          max_queue_size: max_queue_size,
          retry_limit: retry_limit
        }
      end

      private

      attr_reader :connections, :max_queue_size, :retry_limit

      def deliver_envelope(envelope)
        connection = connections[envelope.subscriber_id]
        return disconnected_outcome(envelope) unless connection

        connection.deliver(envelope)
      end

      def disconnected_outcome(envelope)
        Outcome.new(
          envelope.subscriber_id,
          :disconnected,
          0,
          0,
          self.class.envelope_digest(envelope),
          nil,
          nil
        )
      end
    end
  end
end
