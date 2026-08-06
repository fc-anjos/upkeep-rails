module RefreshSync
  # Coalesces refreshes: at most one Turbo page refresh per stream per window.
  # A write storm inside the window collapses to a single broadcast.
  class Debouncer
    def initialize(window: 0.3, broadcaster: nil)
      @window = window
      @broadcaster = broadcaster || default_broadcaster
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @due = {} # stream => monotonic due time
      @thread = nil
    end

    def schedule(stream)
      @mutex.synchronize do
        @due[stream] ||= now + @window
        ensure_worker
        @cond.signal
      end
    end

    def pending_count = @mutex.synchronize { @due.size }

    private

    def default_broadcaster
      ->(stream) { Turbo::StreamsChannel.broadcast_refresh_to(stream) }
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def ensure_worker
      return if @thread&.alive?
      @thread = Thread.new { work }
    end

    def work
      loop do
        ready = []
        @mutex.synchronize do
          if @due.empty?
            @cond.wait(@mutex, 5)
            next
          end
          wake_at = @due.values.min
          wait_for = wake_at - now
          if wait_for > 0
            @cond.wait(@mutex, wait_for)
            next
          end
          current = now
          @due.each { |stream, due_at| ready << stream if due_at <= current }
          ready.each { |stream| @due.delete(stream) }
        end
        ready.each do |stream|
          begin
            @broadcaster.call(stream)
            RefreshSync.stats[:refreshes_broadcast] += 1
          rescue => e
            warn "RefreshSync broadcast failed: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end
