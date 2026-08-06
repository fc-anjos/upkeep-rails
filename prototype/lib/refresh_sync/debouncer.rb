module RefreshSync
  # Coalesces deliveries: at most one action per key per window. A write
  # storm inside the window collapses to a single refresh/broadcast.
  #
  # A global refresh budget (with jitter) caps Tier P refresh storms: at most
  # `refresh_budget` refresh actions dispatch per tick; the excess is
  # re-scheduled with jittered delay so a table-level write burst spreads
  # over several windows instead of stampeding the app with N simultaneous
  # re-GETs.
  class Debouncer
    Entry = Struct.new(:due, :kind, :action)

    def initialize(window: 0.3, broadcaster: nil, refresh_budget: nil, jitter: 0.3)
      @window = window
      @broadcaster = broadcaster || default_broadcaster
      @refresh_budget = refresh_budget
      @jitter = jitter
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @due = {} # key => Entry
      @thread = nil
    end

    def schedule(key, kind: :refresh, &action)
      action ||= ->() { @broadcaster.call(key) }
      @mutex.synchronize do
        @due[key] ||= Entry.new(now + @window, kind, action)
        ensure_worker
        @cond.signal
      end
    end

    def cancel(key)
      @mutex.synchronize { @due.delete(key) }
    end

    def pending_count = @mutex.synchronize { @due.size }

    private

    def default_broadcaster
      ->(stream) do
        Turbo::StreamsChannel.broadcast_refresh_to(stream)
        RefreshSync.stats[:refreshes_broadcast] += 1
      end
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
          wake_at = @due.values.map(&:due).min
          wait_for = wake_at - now
          if wait_for > 0
            @cond.wait(@mutex, wait_for)
            next
          end
          current = now
          ready = @due.select { |_k, e| e.due <= current }.to_a

          # Refresh budget: dispatch at most @refresh_budget refreshes this
          # tick; defer the rest with jitter.
          if @refresh_budget
            refreshes = ready.select { |_k, e| e.kind == :refresh }
            if refreshes.size > @refresh_budget
              refreshes.drop(@refresh_budget).each do |key, entry|
                entry.due = current + @window * (1 + rand * @jitter)
                ready.delete([key, entry])
                RefreshSync.stats[:refreshes_deferred] += 1
              end
            end
          end
          ready.each { |key, _e| @due.delete(key) }
        end
        ready.each do |_key, entry|
          begin
            entry.action.call
          rescue => e
            warn "RefreshSync dispatch failed: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end
