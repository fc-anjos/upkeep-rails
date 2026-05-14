# frozen_string_literal: true

module Upkeep
  module Subscriptions
    class AsyncDurableWriter
      DEFAULT_BATCH_SIZE = 100
      DEFAULT_FLUSH_INTERVAL = 1.0
      Job = Data.define(:subscription, :entries)

      def initialize(batch_size: DEFAULT_BATCH_SIZE, flush_interval: DEFAULT_FLUSH_INTERVAL, &persist_batch)
        @batch_size = batch_size
        @flush_interval = flush_interval
        @persist_batch = persist_batch
        @mutex = Mutex.new
        @available = ConditionVariable.new
        @drained = ConditionVariable.new
        @queue = []
        @pending = 0
        @closed = false
        @flush_now = false
        @errors = []
        @worker = Thread.new { work_loop }
        @worker.name = "upkeep-durable-writer" if @worker.respond_to?(:name=)
      end

      def enqueue(subscription, entries:)
        @mutex.synchronize do
          raise IOError, "Upkeep durable writer is closed" if @closed

          @queue << Job.new(subscription, entries)
          @pending += 1
          @available.signal
        end
      end

      def drain(raise_errors: true)
        errors = @mutex.synchronize do
          @flush_now = true
          @available.broadcast
          @drained.wait(@mutex) while @pending.positive?
          drained_errors = @errors
          @errors = [] if raise_errors
          drained_errors
        end

        raise errors.first if raise_errors && errors.any?

        errors
      end

      def shutdown
        drain(raise_errors: false)
        @mutex.synchronize do
          @closed = true
          @available.broadcast
        end
        @worker.join
      end

      private

      def work_loop
        loop do
          batch = next_batch
          break unless batch

          begin
            @persist_batch.call(batch)
          rescue StandardError => error
            @mutex.synchronize { @errors << error }
          ensure
            @mutex.synchronize do
              @pending -= batch.size
              @drained.broadcast if @pending.zero?
            end
          end
        end
      end

      def next_batch
        @mutex.synchronize do
          @available.wait(@mutex) while @queue.empty? && !@closed
          return nil if @queue.empty? && @closed

          wait_for_batch_fill
          @flush_now = false
          @queue.shift(@batch_size)
        end
      end

      def wait_for_batch_fill
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @flush_interval
        while @queue.size < @batch_size && !@closed && !@flush_now
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless remaining.positive?

          @available.wait(@mutex, remaining)
        end
      end
    end
  end
end
