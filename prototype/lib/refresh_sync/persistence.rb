require "securerandom"
require "json"

module RefreshSync
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
      self.table_name = "refresh_sync_cohorts"
    end

    class SurfaceRow < ActiveRecord::Base
      self.table_name = "refresh_sync_surfaces"
    end

    class ClaimRow < ActiveRecord::Base
      self.table_name = "refresh_sync_claims"
    end

    def self.setup!
      conn = ActiveRecord::Base.connection
      unless conn.table_exists?(:refresh_sync_cohorts)
        conn.create_table :refresh_sync_cohorts do |t|
          t.string :stream, null: false
          t.string :deploy_key, null: false
          t.text :read_set_json, null: false
          t.text :surfaces_json, null: false, default: "[]"
          t.text :tables_json, null: false, default: "[]"
          t.datetime :heartbeat_at
        end
      end
      unless conn.table_exists?(:refresh_sync_surfaces)
        conn.create_table :refresh_sync_surfaces do |t|
          t.string :name, null: false
          t.string :deploy_key, null: false
          t.text :state_json
        end
        conn.add_index :refresh_sync_surfaces, [:name, :deploy_key], unique: true
      end
      unless conn.table_exists?(:refresh_sync_claims)
        conn.create_table :refresh_sync_claims do |t|
          t.string :claim_key, null: false
          t.datetime :created_at
        end
        conn.add_index :refresh_sync_claims, :claim_key, unique: true
      end
    end

    def self.wipe!
      CohortRow.delete_all
      SurfaceRow.delete_all
      ClaimRow.delete_all
    end

    WATCH_CACHE_TTL = 0.05

    def initialize
      @watch_cache = nil
      @watch_cache_at = 0.0
      @mutex = Mutex.new
    end

    def register(read_set:, surfaces: [], identity: nil)
      id = SecureRandom.hex(8)
      stream = "refresh_sync:cohort:#{id}"
      CohortRow.create!(
        stream: stream,
        deploy_key: RefreshSync.deploy_key,
        read_set_json: JSON.generate(read_set.to_h),
        surfaces_json: JSON.generate(surfaces),
        tables_json: JSON.generate(read_set.tables.keys),
        heartbeat_at: Time.now
      )
      @mutex.synchronize { @watch_cache = nil }
      MemoryStore::Cohort.new(id: id, stream: stream, read_set: read_set,
                              surfaces: surfaces, identity: identity)
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
      CohortRow.where("tables_json LIKE ?", "%#{("\"" + change.table + "\"")}%").filter_map do |row|
        read_set = ReadSet.from_h(JSON.parse(row.read_set_json))
        next unless read_set.matches?(change)
        MemoryStore::Cohort.new(id: row.id, stream: row.stream, read_set: read_set,
                                surfaces: JSON.parse(row.surfaces_json))
      end
    end

    def reset!
      self.class.wipe!
      @mutex.synchronize { @watch_cache = nil }
    end

    private

    def watch_set
      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @watch_cache.nil? || now - @watch_cache_at > WATCH_CACHE_TTL
          @watch_cache = CohortRow.pluck(:tables_json)
                                  .flat_map { |j| JSON.parse(j) }.to_set
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
      ActiveRecordStore::ClaimRow.create!(claim_key: "#{key}:#{window_id}", created_at: Time.now)
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end
  end

  # Surface promotion state in the shared store: every lookup rehydrates
  # from the row (no process-local caching), every mutation persists.
  class ActiveRecordSurfaceRegistry
    class PersistedSurface < Surface
      attr_accessor :row

      def persist!
        row.update!(state_json: JSON.generate(state_dump))
        nil
      end
    end

    def lookup(name, deploy_key: RefreshSync.deploy_key)
      row = ActiveRecordStore::SurfaceRow.find_by(name: name, deploy_key: deploy_key)
      row && hydrate(row)
    end

    def upsert(name, deploy_key: RefreshSync.deploy_key)
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
