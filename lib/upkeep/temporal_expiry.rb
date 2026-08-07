module Upkeep
  # Scopes that bake "today" into their predicate (due_on >= Time.zone.today)
  # are correct at capture and silently wrong at the next local midnight — no
  # write ever signals the drift. When a captured predicate (hash or parsed
  # fragment) carries a date/datetime literal on the capture day, the cohort
  # is stamped with an expiry at the next local-date rollover; at expiry the
  # cohort is treated as stale and its refresh is scheduled, so the re-GET
  # recaptures with the new day's predicate. Membership drift heals at the
  # boundary instead of whenever the next unrelated write lands.
  #
  # Time flows through the injectable Upkeep.clock; the monitor thread is a
  # delivery convenience — tests pin the clock and call fire_due! directly.
  module TemporalExpiry
    DATE_PREFIX = /\A(\d{4}-\d{2}-\d{2})/

    class << self
      # The expiry for this read set: the next local midnight when any
      # predicate value's date component equals the capture day, else nil.
      def expiry_for(read_set, now: Upkeep.now)
        today = now.to_date
        return nil unless read_set.tables.values.any? do |deps|
          (deps.predicates + deps.membership_predicates).any? do |pred|
            predicate_values(pred).any? { |value| date_of(value) == today }
          end
        end
        (today + 1).to_time
      end

      # Expire every due cohort: emit the classified event and schedule the
      # cohort's refresh — Tier P delivery, the sole correctness mechanism,
      # recaptures the page with the new day's predicate.
      def fire_due!(now: Upkeep.now)
        expired = Upkeep.store.expire_due!(now)
        expired.each do |cohort|
          Upkeep.stats[:temporal_expiries] += 1
          ActiveSupport::Notifications.instrument(
            "cohort_temporal_expiry.upkeep", stream: cohort.stream, path: cohort.path
          )
          Upkeep.debouncer.schedule(cohort.stream)
        end
        expired
      end

      # Arm the monitor for an expiry time. One thread, woken early when a
      # nearer expiry arrives; it re-reads Upkeep.clock on every pass so a
      # test-pinned clock short-circuits to an immediate fire.
      def arm(at)
        mutex.synchronize do
          @next_due = at if @next_due.nil? || at < @next_due
          ensure_worker
          @cond.signal
        end
      end

      def reset!
        mutex.synchronize { @next_due = nil }
      end

      private

      def mutex
        @mutex ||= begin
          @cond = ConditionVariable.new
          Mutex.new
        end
      end

      def ensure_worker
        return if @thread&.alive?
        @thread = Thread.new { work }
      end

      def work
        loop do
          due = mutex.synchronize do
            @cond.wait(mutex, 5) if @next_due.nil?
            next nil if @next_due.nil?
            wait = @next_due.to_f - Upkeep.now.to_f
            if wait.positive?
              @cond.wait(mutex, [wait, 5].min)
              nil
            else
              @next_due = nil
              true
            end
          end
          fire_safely if due
        end
      end

      def fire_safely
        fire_due!
      rescue StandardError => e
        warn "Upkeep temporal expiry failed: #{e.class}: #{e.message}"
      end

      def predicate_values(pred)
        if SqlPredicate.fragment?(pred)
          SqlPredicate.literal_values(SqlPredicate.unwrap(pred))
        else
          pred.values.flatten(1)
        end
      end

      def date_of(value)
        case value
        when DateTime, Time then value.to_date
        when Date then value
        when String then (match = DATE_PREFIX.match(value)) && Date.parse(match[1])
        end
      rescue ArgumentError
        nil
      end
    end
  end
end
