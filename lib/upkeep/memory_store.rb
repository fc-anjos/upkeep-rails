require "securerandom"

module Upkeep
  # One cohort = one rendered page view: a stream name, its read set, and
  # the names of shared-surface candidates it rendered.
  # (The real gem adds durability, TTL leases and the signed activation
  # handshake carried over from the existing design; not needed for the proof.)
  class MemoryStore
    # baselines: {surface_name => {node_address => digest}} — the cohort's
    # region-digest baseline, seeded from its own capture-time render and
    # advanced after every region delivery it receives. Region broadcasts
    # are diffed per cohort against THIS, so the first write after
    # registration sends only what actually changed for that viewer.
    # expires_at: temporal-literal expiry (a "today"-baked predicate goes
    # stale at the next local-date rollover; see TemporalExpiry).
    Cohort = Struct.new(:id, :stream, :read_set, :surfaces, :identity, :baselines, :path,
                        :expires_at, keyword_init: true)

    def initialize
      @mutex = Mutex.new
      @cohorts = {}
      @watched_tables = Set.new
    end

    def register(read_set:, surfaces: [], baselines: {}, identity: nil, path: nil,
                 expires_at: nil)
      id = SecureRandom.hex(8)
      cohort = Cohort.new(id: id, stream: "upkeep:cohort:#{id}",
                          read_set: read_set, surfaces: surfaces,
                          identity: identity, baselines: baselines, path: path,
                          expires_at: expires_at)
      @mutex.synchronize do
        @cohorts[id] = cohort
        @watched_tables.merge(read_set.tables.keys)
      end
      cohort
    end

    def cohorts_for_surface(name)
      @mutex.synchronize do
        @cohorts.values.select { |c| c.surfaces.include?(name) }
      end
    end

    def update_baseline(stream, surface_name, digests)
      @mutex.synchronize do
        cohort = @cohorts.values.find { |c| c.stream == stream }
        next unless cohort
        (cohort.baselines ||= {})[surface_name] = digests
      end
    end

    def watching?(table)
      @mutex.synchronize { @watched_tables.include?(table) }
    end

    def cohort_count
      @mutex.synchronize { @cohorts.size }
    end

    # Columns appearing in registered cohort predicates for `table` — the
    # RETURNING projection candidates (derived from evidence, never
    # configured).
    def predicate_columns(table)
      @mutex.synchronize do
        @cohorts.values.each_with_object(Set.new) do |cohort, columns|
          deps = cohort.read_set.tables[table]
          next unless deps
          (deps.predicates + deps.membership_predicates).each do |pred|
            columns.merge(Verdict.predicate_columns(pred) || [])
          end
        end.to_a
      end
    end

    # Subscription bookkeeping for the channel hook: first verified
    # subscription activates the cohort, later ones are reconnects.
    def mark_subscribed(stream)
      @mutex.synchronize do
        cohort = @cohorts.values.find { |c| c.stream == stream }
        next nil unless cohort
        @subscribed ||= Set.new
        if @subscribed.include?(stream)
          :reconnect
        else
          @subscribed << stream
          :first
        end
      end
    end

    def matching_cohorts(change)
      @mutex.synchronize do
        @cohorts.values.select { |c| c.read_set.matches?(change) }
      end
    end

    def matching_streams(change) = matching_cohorts(change).map(&:stream)

    # Remove and return every cohort whose temporal expiry has passed —
    # their pages hold yesterday's predicate; the caller schedules their
    # refresh (re-registration happens on the re-GET).
    def expire_due!(now = Upkeep.now)
      @mutex.synchronize do
        expired = @cohorts.values.select { |c| c.expires_at && c.expires_at <= now }
        expired.each { |c| @cohorts.delete(c.id) }
        expired
      end
    end

    def reset!
      @mutex.synchronize do
        @cohorts.clear
        @watched_tables.clear
      end
    end
  end
end
