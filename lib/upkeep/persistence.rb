require "securerandom"
require "json"

module Upkeep
  # ActiveRecord-backed cohort store: one cohorts table (stream, serialized
  # read set, surface names, deploy key, heartbeat), plus a claims table for
  # cross-process coalescing and a surfaces table for shared promotion state.
  #
  # The coordinator spec said "one table"; promotion state is deliberately a
  # second table because it is per-SURFACE, shared by many cohorts —
  # duplicating it per cohort row would create exactly the coherence bugs
  # the shared store exists to prevent. Claims are a third (two columns).
  class ActiveRecordStore
    class CohortRow < ActiveRecord::Base
      self.table_name = "upkeep_cohorts"
    end

    class SurfaceRow < ActiveRecord::Base
      self.table_name = "upkeep_surfaces"
    end

    class ClaimRow < ActiveRecord::Base
      self.table_name = "upkeep_claims"
    end

    # One row per (cohort, table it depends on): the indexed inverse of the
    # read set's table list, so write matching is an indexed lookup instead
    # of a tables_json LIKE scan.
    class CohortTableRow < ActiveRecord::Base
      self.table_name = "upkeep_cohort_tables"
    end

    def self.setup!
      conn = ActiveRecord::Base.connection
      unless conn.table_exists?(:upkeep_cohorts)
        conn.create_table :upkeep_cohorts do |t|
          t.string :stream, null: false
          t.string :deploy_key, null: false
          # The captured request path: pure legibility (upkeep:report names
          # pages by it); matching never reads it.
          t.string :path
          # Viewer identity (nil for unauthenticated pages): the key
          # per-member divergence ejection and re-admission act on.
          t.string :identity
          t.text :read_set_json, null: false
          t.text :surfaces_json, null: false, default: "[]"
          t.text :baselines_json, null: false, default: "{}"
          t.datetime :heartbeat_at
          # First verified cable subscription stamps this; later
          # subscriptions on the same stream are reconnects (resync refresh).
          t.datetime :activated_at
          # Temporal-literal expiry: a "today"-baked predicate goes stale at
          # the next local-date rollover (TemporalExpiry schedules a refresh).
          t.datetime :expires_at
        end
        conn.add_index :upkeep_cohorts, :stream, unique: true
      end
      unless conn.table_exists?(:upkeep_cohort_tables)
        conn.create_table :upkeep_cohort_tables do |t|
          t.bigint :cohort_id, null: false
          t.string :table_name, null: false
        end
        conn.add_index :upkeep_cohort_tables, :table_name
        conn.add_index :upkeep_cohort_tables, :cohort_id
      end
      unless conn.table_exists?(:upkeep_surfaces)
        conn.create_table :upkeep_surfaces do |t|
          t.string :name, null: false
          t.string :deploy_key, null: false
          # Status is duplicated out of state_json into its own column so
          # the dispatch-time claim can be a single atomic UPDATE ... WHERE
          # status IN ('shared','region_shared') — the store-side
          # compare-and-set that closes the demotion race window. SQLite
          # and Postgres both execute a single-statement conditional
          # update atomically.
          t.string :status, null: false, default: "observing"
          t.datetime :dispatched_at
          # Optimistic lock: two processes persisting surface state
          # concurrently (say, ejecting different members) must not
          # lose either update — the stale writer reloads and reapplies.
          t.integer :lock_version, null: false, default: 0
          t.text :state_json
        end
        conn.add_index :upkeep_surfaces, [:name, :deploy_key], unique: true
      end
      unless conn.table_exists?(:upkeep_claims)
        conn.create_table :upkeep_claims do |t|
          t.string :claim_key, null: false
          t.datetime :created_at
        end
        conn.add_index :upkeep_claims, :claim_key, unique: true
      end
    end

    def self.wipe!
      CohortRow.delete_all
      CohortTableRow.delete_all
      SurfaceRow.delete_all
      ClaimRow.delete_all
    end

    WATCH_CACHE_TTL = 0.05

    # Lifecycle bounds: the tables must not grow without limit.
    #   - a cohort whose page never opened a cable subscription is dead
    #     weight after UNACTIVATED_TTL (tab closed before connecting,
    #     crawler with cable blocked, ...)
    #   - an activated cohort with no heartbeat (no live subscription
    #     touch) for COHORT_TTL has no browser behind it anymore
    #   - a claim row outlives its debounce window by definition; anything
    #     older than CLAIM_TTL is a dead claim
    # Sweeping is opportunistic: piggybacked on registration at most once
    # per SWEEP_INTERVAL, so no separate process or scheduler is required.
    UNACTIVATED_TTL = 10 * 60
    COHORT_TTL = 6 * 60 * 60
    CLAIM_TTL = 60 * 60
    SWEEP_INTERVAL = 60

    def initialize
      @watch_cache = nil
      @watch_cache_at = 0.0
      @mutex = Mutex.new
      @last_sweep_at = 0.0
      @predicate_columns_cache = {}
    end

    def register(read_set:, surfaces: [], baselines: {}, identity: nil, path: nil,
                 expires_at: nil)
      id = SecureRandom.hex(8)
      stream = "upkeep:cohort:#{id}"
      row = CohortRow.create!(
        stream: stream,
        deploy_key: Upkeep.deploy_key,
        identity: identity,
        path: path,
        read_set_json: JSON.generate(read_set.to_h),
        surfaces_json: JSON.generate(surfaces),
        baselines_json: JSON.generate(baselines),
        heartbeat_at: Upkeep.now,
        expires_at: expires_at
      )
      tables = read_set.tables.keys
      if tables.any?
        CohortTableRow.insert_all!(tables.map { |t| { cohort_id: row.id, table_name: t } })
      end
      @mutex.synchronize do
        @watch_cache = nil
        tables.each { |t| @predicate_columns_cache.delete(t) }
      end
      sweep_opportunistically
      MemoryStore::Cohort.new(id: id, stream: stream, read_set: read_set,
                              surfaces: surfaces, identity: identity,
                              baselines: baselines, path: path,
                              expires_at: expires_at)
    end

    # Remove and return every cohort whose temporal expiry has passed —
    # their pages hold yesterday's predicate; the caller schedules their
    # refresh (re-registration happens on the re-GET).
    def expire_due!(now = Upkeep.now)
      rows = CohortRow.where(expires_at: ..now).where.not(expires_at: nil).to_a
      return [] if rows.empty?
      expired = rows.map { |row| hydrate_cohort(row) }
      CohortRow.where(id: rows.map(&:id)).delete_all
      CohortTableRow.where(cohort_id: rows.map(&:id)).delete_all
      @mutex.synchronize do
        @watch_cache = nil
        @predicate_columns_cache.clear
      end
      expired
    end

    # Deletes what no browser is behind anymore. Cheap indexed deletes;
    # safe to run from any process at any time.
    def sweep!(now: Upkeep.now)
      dead = CohortRow.where(activated_at: nil)
                      .where(heartbeat_at: ...now - UNACTIVATED_TTL).pluck(:id)
      dead += CohortRow.where.not(activated_at: nil)
                       .where(heartbeat_at: ...now - COHORT_TTL).pluck(:id)
      if dead.any?
        CohortRow.where(id: dead).delete_all
        CohortTableRow.where(cohort_id: dead).delete_all
        @mutex.synchronize do
          @watch_cache = nil
          @predicate_columns_cache.clear
        end
      end
      claims = ClaimRow.where(created_at: ...now - CLAIM_TTL).delete_all
      Upkeep.stats[:cohorts_swept] += dead.size
      Upkeep.stats[:claims_swept] += claims
      { cohorts: dead.size, claims: claims }
    end

    def cohort_count = CohortRow.count

    # A live subscription's periodic touch (the channel pings it on
    # subscribe): keeps the cohort out of the sweeper's reach.
    def heartbeat(stream)
      CohortRow.where(stream: stream).update_all(heartbeat_at: Upkeep.now)
    end

    # Cached table watch-set with a short TTL; a miss re-checks the DB once
    # so a cohort registered by another process is never silently ignored.
    # (Production: a pub/sub-invalidated cache or a bloom filter.)
    def watching?(table)
      return true if watch_set.include?(table)
      @mutex.synchronize { @watch_cache = nil }
      watch_set.include?(table)
    end

    def matching_cohorts(change)
      ids = CohortTableRow.where(table_name: change.table).select(:cohort_id)
      CohortRow.where(id: ids).filter_map do |row|
        read_set = ReadSet.from_h(JSON.parse(row.read_set_json))
        next unless read_set.matches?(change)
        hydrate_cohort(row, read_set: read_set)
      end
    end

    # Columns appearing in registered cohort predicates for `table` — the
    # RETURNING projection candidates (derived from stored evidence).
    # Cached per table: re-parsing every cohort's read-set JSON on each bulk
    # write is wasted work. Registration in THIS process invalidates
    # directly; other processes' registrations are covered by the TTL. A
    # stale entry only under-projects the RETURNING columns — the verdict
    # for the missing column falls back to conservative refresh (fails open
    # on freshness, never on identity), so a short TTL is sound.
    PREDICATE_COLUMNS_TTL = 30 # seconds

    def predicate_columns(table)
      @mutex.synchronize do
        cached = @predicate_columns_cache[table]
        return cached[:columns] if cached && cached[:expires_at] > Upkeep.now
      end
      columns = compute_predicate_columns(table)
      @mutex.synchronize do
        @predicate_columns_cache[table] =
          { columns: columns, expires_at: Upkeep.now + PREDICATE_COLUMNS_TTL }
      end
      columns
    end

    def cohorts_for_surface(name)
      CohortRow.where("surfaces_json LIKE ?", "%#{("\"" + name + "\"")}%").map do |row|
        hydrate_cohort(row)
      end
    end

    # First verified cable subscription activates the cohort; later ones are
    # reconnects. Atomic conditional UPDATE so two racing subscribes can't
    # both claim :first.
    def mark_subscribed(stream)
      now = Upkeep.now
      claimed = CohortRow.where(stream: stream, activated_at: nil)
                         .update_all(activated_at: now, heartbeat_at: now) == 1
      return :first if claimed
      if CohortRow.where(stream: stream).exists?
        heartbeat(stream)
        :reconnect
      end
    end

    def update_baseline(stream, surface_name, digests)
      row = CohortRow.find_by(stream: stream)
      return unless row
      baselines = JSON.parse(row.baselines_json.presence || "{}")
      baselines[surface_name] = digests
      row.update!(baselines_json: JSON.generate(baselines))
    end

    def reset!
      self.class.wipe!
      @mutex.synchronize do
        @watch_cache = nil
        @predicate_columns_cache = {}
      end
    end

    private

    def compute_predicate_columns(table)
      ids = CohortTableRow.where(table_name: table).select(:cohort_id)
      CohortRow.where(id: ids).pluck(:read_set_json).each_with_object(Set.new) do |json, columns|
        deps = JSON.parse(json)[table]
        next unless deps
        aggregate_preds = deps.fetch("aggregates", []).flat_map { |a| a["predicates"] }
        (deps.fetch("predicates", []) + deps.fetch("membership_predicates", []) +
         aggregate_preds).each do |pred|
          columns.merge(Verdict.predicate_columns(pred) || [])
        end
      end.to_a
    end

    def sweep_opportunistically
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      run = @mutex.synchronize do
        next false if now - @last_sweep_at < SWEEP_INTERVAL
        @last_sweep_at = now
        true
      end
      sweep! if run
    end

    def hydrate_cohort(row, read_set: nil)
      read_set ||= ReadSet.from_h(JSON.parse(row.read_set_json))
      MemoryStore::Cohort.new(
        id: row.id, stream: row.stream, read_set: read_set,
        surfaces: JSON.parse(row.surfaces_json),
        identity: row.identity, path: row.path,
        baselines: JSON.parse(row.baselines_json.presence || "{}"),
        expires_at: row.expires_at
      )
    end

    def watch_set
      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @watch_cache.nil? || now - @watch_cache_at > WATCH_CACHE_TTL
          @watch_cache = CohortTableRow.distinct.pluck(:table_name).to_set
          @watch_cache_at = now
        end
        @watch_cache
      end
    end
  end

  # Cross-process debounce claim: one row per (key, window); the process
  # that inserts first broadcasts, the loser drops its duplicate.
  class DbClaimer
    def call(key, window_id)
      ActiveRecordStore::ClaimRow.create!(claim_key: "#{key}:#{window_id}", created_at: Upkeep.now)
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end
  end

  # Surface promotion state in the shared store: every lookup rehydrates
  # from the row (no process-local caching), every mutation persists.
  class ActiveRecordSurfaceRegistry
    class PersistedSurface < Surface
      TIER_S_STATUSES = %w[shared region_shared].freeze

      attr_accessor :row

      def persist!
        row.update!(status: status.to_s, state_json: JSON.generate(state_dump))
        nil
      end

      # Optimistic-lock retry: when another process persisted between this
      # object's hydration and its persist (the two-ejections race), reload
      # the fresh state and re-apply the mutation on top of it — both
      # updates survive. Bounded; a pathological livelock surfaces loudly
      # instead of silently dropping state.
      def mutate(&block)
        attempts = 0
        begin
          block.call
          persist!
        rescue ActiveRecord::StaleObjectError
          attempts += 1
          raise if attempts > 3
          fresh = row.reload
          state_load(JSON.parse(fresh.state_json)) if fresh.state_json.presence
          retry
        end
      end

      private

      # Post-render gate: one atomic conditional UPDATE against the row's
      # status column. Either this statement observes a tier-S status and
      # claims the dispatch, or a demotion (which persists status =
      # 'personal') committed first and the claim fails — the DB serializes
      # the two writes, so there is no read-then-act window left.
      def claim_dispatch!
        ActiveRecordStore::SurfaceRow
          .where(id: row.id, status: TIER_S_STATUSES)
          .update_all(dispatched_at: Upkeep.now) == 1
      end
    end

    def lookup(name, deploy_key: Upkeep.deploy_key)
      row = ActiveRecordStore::SurfaceRow.find_by(name: name, deploy_key: deploy_key)
      row && hydrate(row)
    end

    def upsert(name, deploy_key: Upkeep.deploy_key)
      row = ActiveRecordStore::SurfaceRow.find_or_create_by!(name: name, deploy_key: deploy_key)
      hydrate(row)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    def hydrate(row)
      surface = PersistedSurface.new(name: row.name, deploy_key: row.deploy_key)
      surface.row = row
      state = row.state_json.presence && JSON.parse(row.state_json)
      surface.state_load(state) if state
      surface
    end
  end
end
