require "securerandom"

module RefreshSync
  # One cohort = one rendered page view: a stream name, its read set, and
  # the names of shared-surface candidates it rendered.
  # (The real gem adds durability, TTL leases and the signed activation
  # handshake carried over from the existing design; not needed for the proof.)
  class MemoryStore
    Cohort = Struct.new(:id, :stream, :read_set, :surfaces, :identity, keyword_init: true)

    def initialize
      @mutex = Mutex.new
      @cohorts = {}
      @watched_tables = Set.new
    end

    def register(read_set:, surfaces: [], identity: nil)
      id = SecureRandom.hex(8)
      cohort = Cohort.new(id: id, stream: "refresh_sync:cohort:#{id}",
                          read_set: read_set, surfaces: surfaces, identity: identity)
      @mutex.synchronize do
        @cohorts[id] = cohort
        @watched_tables.merge(read_set.tables.keys)
      end
      cohort
    end

    def watching?(table)
      @mutex.synchronize { @watched_tables.include?(table) }
    end

    def matching_cohorts(change)
      @mutex.synchronize do
        @cohorts.values.select { |c| c.read_set.matches?(change) }
      end
    end

    def matching_streams(change) = matching_cohorts(change).map(&:stream)

    def reset!
      @mutex.synchronize do
        @cohorts.clear
        @watched_tables.clear
      end
    end
  end
end
