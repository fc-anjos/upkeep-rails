require "securerandom"

module RefreshSync
  # One cohort = one rendered page view: a stream name plus its read set.
  # (The real gem adds durability, TTL leases and the signed activation
  # handshake carried over from the existing design; not needed for the proof.)
  class MemoryStore
    Cohort = Struct.new(:id, :stream, :read_set, :identity, keyword_init: true)

    def initialize
      @mutex = Mutex.new
      @cohorts = {}
      @watched_tables = Set.new
    end

    def register(read_set:, identity: nil)
      id = SecureRandom.hex(8)
      cohort = Cohort.new(id: id, stream: "refresh_sync:cohort:#{id}", read_set: read_set, identity: identity)
      @mutex.synchronize do
        @cohorts[id] = cohort
        @watched_tables.merge(read_set.tables.keys)
      end
      cohort
    end

    def watching?(table)
      @mutex.synchronize { @watched_tables.include?(table) }
    end

    def matching_streams(change)
      @mutex.synchronize do
        @cohorts.values.select { |c| c.read_set.matches?(change) }.map(&:stream)
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
