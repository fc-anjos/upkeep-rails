# frozen_string_literal: true

module Upkeep
  module Delivery
    class AsyncDispatcher
      def initialize(batch_window: 0.01, &deliver)
        @deliver = deliver
        @batch_window = batch_window
        @jobs = []
        @mutex = Mutex.new
        @available = ConditionVariable.new
        @idle = ConditionVariable.new
        @pending_jobs = 0
        @last_error = nil
        @stopping = false
        @worker = Thread.new { work_loop }
      end

      def enqueue(changes)
        changes = Array(changes)
        return Transport::DispatchReport.new([]) if changes.empty?

        @mutex.synchronize do
          raise @last_error if @last_error

          @pending_jobs += 1
          @jobs << changes
          @available.signal
        end

        Transport::DispatchReport.new([])
      end

      def drain
        @mutex.synchronize do
          @idle.wait(@mutex) until @pending_jobs.zero?
          raise @last_error if @last_error
        end
      end

      def shutdown
        error = nil
        begin
          drain
        rescue StandardError => shutdown_error
          error = shutdown_error
        ensure
          @mutex.synchronize do
            @stopping = true
            @available.signal
          end
          @worker.join
        end

        raise error if error
      end

      private

      attr_reader :deliver, :batch_window

      def work_loop
        loop do
          batch = next_batch
          break unless batch

          begin
            deliver.call(batch)
          rescue StandardError => error
            @mutex.synchronize { @last_error = error }
          ensure
            complete_jobs(batch.size)
          end
        end
      end

      def next_batch
        @mutex.synchronize do
          @available.wait(@mutex) while @jobs.empty? && !@stopping
          return nil if @jobs.empty? && @stopping

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + batch_window
          while !@stopping
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break unless remaining.positive?

            @available.wait(@mutex, remaining)
          end

          @jobs.shift(@jobs.length)
        end
      end

      def complete_jobs(count)
        @mutex.synchronize do
          @pending_jobs -= count
          @idle.broadcast if @pending_jobs.zero?
        end
      end
    end
  end
end
