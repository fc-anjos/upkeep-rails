# frozen_string_literal: true

module Upkeep
  module Delivery
    class AsyncDispatcher
      def initialize(&deliver)
        @deliver = deliver
        @queue = Queue.new
        @mutex = Mutex.new
        @idle = ConditionVariable.new
        @pending_jobs = 0
        @last_error = nil
        @worker = Thread.new { work_loop }
      end

      def enqueue(changes)
        changes = Array(changes)
        return Transport::DispatchReport.new([]) if changes.empty?

        @mutex.synchronize { @pending_jobs += 1 }
        @queue << changes

        Transport::DispatchReport.new([])
      end

      def drain
        @mutex.synchronize do
          @idle.wait(@mutex) until @pending_jobs.zero?
          raise @last_error if @last_error
        end
      end

      def shutdown
        drain
        @queue << :stop
        @worker.join
      end

      private

      attr_reader :deliver, :queue

      def work_loop
        loop do
          item = queue.pop
          break if item == :stop

          begin
            deliver.call(item)
          rescue StandardError => error
            @mutex.synchronize { @last_error = error }
          ensure
            complete_job
          end
        end
      end

      def complete_job
        @mutex.synchronize do
          @pending_jobs -= 1
          @idle.broadcast if @pending_jobs.zero?
        end
      end
    end
  end
end
