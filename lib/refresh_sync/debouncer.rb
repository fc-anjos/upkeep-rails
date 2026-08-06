module RefreshSync
  # Coalesces deliveries: at most one action per key per window. A write
  # storm inside the window collapses to a single refresh/broadcast.
  #
  # Refresh entries carry an optional originating request id (write committed
  # during a captured GET); it is stamped onto the refresh tag so Turbo 8's
  # native client-side guard discards the refresh on the tab whose GET caused
  # it. Two writes with different origins coalesce to an UNSTAMPED refresh —
  # suppressing would hide the other write from the origin tab.
  #
  # A global refresh budget (with jitter) caps Tier P refresh storms.
  #
  # An optional claimer ->(key, window_id) -> bool provides cross-process
  # coalescing: the entry is dispatched only if the claim is won (backed by a
  # unique DB row in the AR store; each process computes the same window id
  # from the wall clock at schedule time).
  class Debouncer
    Entry = Struct.new(:due, :kind, :action, :request_id, :claim_window)

    def initialize(window: 0.3, broadcaster: nil, refresh_budget: nil, jitter: 0.3, claimer: nil)
      @window = window
      @broadcaster = broadcaster
      @refresh_budget = refresh_budget
      @jitter = jitter
      @claimer = claimer
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @due = {} # key => Entry
      @thread = nil
    end

    def schedule(key, kind: :refresh, request_id: nil, &action)
      action ||= default_action(key)
      @mutex.synchronize do
        if (entry = @due[key])
          entry.request_id = nil if entry.request_id != request_id
        else
          claim_window = ((Time.now.to_f + @window) / @window).floor
          @due[key] = Entry.new(now + @window, kind, action, request_id, claim_window)
        end
        ensure_worker
        @cond.signal
      end
    end

    def cancel(key)
      @mutex.synchronize { @due.delete(key) }
    end

    def pending_count = @mutex.synchronize { @due.size }

    private

    def default_action(key)
      if @broadcaster
        proc { |_entry| @broadcaster.call(key) }
      else
        proc do |entry|
          attributes = entry&.request_id ? { request_id: entry.request_id } : {}
          Turbo::StreamsChannel.broadcast_refresh_to(key, **attributes)
          RefreshSync.stats[:refreshes_broadcast] += 1
        end
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
        ready.each do |key, entry|
          begin
            if @claimer && !@claimer.call(key, entry.claim_window)
              RefreshSync.stats[:claims_lost] += 1
              next
            end
            entry.action.call(entry)
          rescue => e
            warn "RefreshSync dispatch failed: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end
