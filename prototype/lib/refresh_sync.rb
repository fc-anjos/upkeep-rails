require "active_support"
require "active_support/core_ext"

# RefreshSync: minimal proof of the from-scratch upkeep design.
#   - read sets recorded from execution (loaded ids + simple where predicates)
#   - coarse write matching (id overlap / predicate / table-level fallback)
#   - delivery is exclusively a debounced Turbo 8 page refresh per cohort
module RefreshSync
  autoload :ReadSet,          "refresh_sync/read_set"
  autoload :Recording,        "refresh_sync/recording"
  autoload :RelationAnalysis, "refresh_sync/relation_analysis"
  autoload :MemoryStore,      "refresh_sync/memory_store"
  autoload :Debouncer,        "refresh_sync/debouncer"
  autoload :Hooks,            "refresh_sync/hooks"
  autoload :Capture,          "refresh_sync/capture"

  Change = Struct.new(:table, :id, :kind, :old_attrs, :new_attrs, keyword_init: true)
  # kind: :insert, :update, :delete, :table (bulk/raw write, row identity unknown)

  class << self
    attr_writer :store, :debouncer

    def store = @store ||= MemoryStore.new
    def debouncer = @debouncer ||= Debouncer.new

    def stats = @stats ||= Hash.new(0)
    def reset_stats! = @stats = Hash.new(0)

    def watching?(table) = store.watching?(table)

    # Entry point for every observed committed write.
    def report_change(change)
      return unless watching?(change.table)
      stats[:writes_analyzed] += 1
      streams = store.matching_streams(change)
      streams.each { |stream| debouncer.schedule(stream) }
    end

    def report_bulk(table)
      report_change(Change.new(table: table, kind: :table))
    end

    def install!
      Hooks.install!
    end
  end
end
