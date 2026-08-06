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
  #
  # Verdict netting: refresh schedules may carry the (fact, verdict) that
  # caused them. A single row that ENTERS the page's dependency set and
  # LEAVES it again inside one window nets to nothing — the page never
  # showed it, the debounced refresh would repaint an identical page — so
  # the entry is dropped at fire time. Anything unprovable (bulk facts,
  # :maybe verdicts, schedules with no fact) marks the entry dirty and
  # fires normally: netting only ever removes work it can prove away.
  class Debouncer
    Entry = Struct.new(:due, :kind, :action, :request_id, :claim_window, :net, :dirty)

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

    def schedule(key, kind: :refresh, request_id: nil, fact: nil, verdict: nil, &action)
      action ||= default_action(key)
      @mutex.synchronize do
        entry = @due[key]
        unless entry
          claim_window = ((Time.now.to_f + @window) / @window).floor
          entry = @due[key] = Entry.new(now + @window, kind, action, request_id, claim_window, {}, false)
        else
          entry.request_id = nil if entry.request_id != request_id
        end
        note_verdict(entry, fact, verdict)
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

    # Only single-row facts with definite verdicts participate in netting;
    # everything else marks the entry dirty (it fires normally).
    def note_verdict(entry, fact, verdict)
      if fact.nil? || verdict.nil? || verdict == :maybe || fact.row_ids.size != 1
        entry.dirty = true
        return
      end
      pair = entry.net[[fact.table, fact.row_ids.first]] ||= [verdict, verdict]
      pair[1] = verdict
    end

    # A refresh whose every tracked row entered the page's dependency set
    # and left it again inside this window repaints an identical page.
    def netted_out?(entry)
      entry.kind == :refresh && !entry.dirty && entry.net.any? &&
        entry.net.values.all? { |first, last| first == :enter && last == :leave }
    end

    def ensure_worker
      return if @thread&.alive?
      @thread = Thread.new { work }
    end

    def work
      loop do
        ready, netted = next_batch
        netted.each do |key, _entry|
          RefreshSync.stats[:refreshes_netted] += 1
          ActiveSupport::Notifications.instrument("refresh_netted.refresh_sync", stream: key)
        end
        ready.each { |key, entry| dispatch(key, entry) }
      end
    end

    # Waits for the next due tick and returns [ready, netted] entries,
    # both removed from the schedule; [[], []] when the wait was a wake-up
    # with nothing due yet.
    def next_batch
      @mutex.synchronize do
        if @due.empty?
          @cond.wait(@mutex, 5)
          return [[], []]
        end
        wait_for = @due.values.map(&:due).min - now
        if wait_for > 0
          @cond.wait(@mutex, wait_for)
          return [[], []]
        end
        current = now
        ready = @due.select { |_k, e| e.due <= current }.to_a
        ready, netted = ready.partition { |_k, e| !netted_out?(e) }
        netted.each { |key, _e| @due.delete(key) }
        apply_refresh_budget(ready, current)
        ready.each { |key, _e| @due.delete(key) }
        [ready, netted]
      end
    end

    # Refresh budget: at most @refresh_budget refreshes per WINDOW (not per
    # tick — two near-simultaneous ticks in one window must share the
    # allowance); defer the rest with jitter. Deferred entries stay in the
    # schedule.
    def apply_refresh_budget(ready, current)
      return unless @refresh_budget
      window_id = (current / @window).floor
      if @budget_window != window_id
        @budget_window = window_id
        @budget_used = 0
      end
      allowance = [@refresh_budget - @budget_used, 0].max
      refreshes = ready.select { |_k, e| e.kind == :refresh }
      refreshes.drop(allowance).each do |key, entry|
        entry.due = current + @window * (1 + rand * @jitter)
        ready.delete([key, entry])
        RefreshSync.stats[:refreshes_deferred] += 1
      end
      @budget_used += [refreshes.size, allowance].min
    end

    def dispatch(key, entry)
      if @claimer && !@claimer.call(key, entry.claim_window)
        RefreshSync.stats[:claims_lost] += 1
        return
      end
      entry.action.call(entry)
    rescue => e
      warn "RefreshSync dispatch failed: #{e.class}: #{e.message}"
    end
  end
end
