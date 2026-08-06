require "active_support"
require "active_support/core_ext"

# RefreshSync: minimal proof of the from-scratch upkeep design.
#   - read sets recorded from execution (loaded ids + simple where predicates)
#   - coarse write matching (id overlap / predicate / table-level fallback)
#   - two-tier delivery:
#       Tier P (default): debounced Turbo 8 page refresh per cohort
#       Tier S (earned):  one scrubbed shared render broadcast per surface
#     Identity fails closed; freshness fails open.
module RefreshSync
  autoload :ReadSet,          "refresh_sync/read_set"
  autoload :Recording,        "refresh_sync/recording"
  autoload :RelationAnalysis, "refresh_sync/relation_analysis"
  autoload :MemoryStore,      "refresh_sync/memory_store"
  autoload :Debouncer,        "refresh_sync/debouncer"
  autoload :Hooks,            "refresh_sync/hooks"
  autoload :Capture,          "refresh_sync/capture"
  autoload :SurfaceHelper,    "refresh_sync/capture"
  autoload :Ambient,          "refresh_sync/ambient"
  autoload :SharedRender,     "refresh_sync/shared_render"
  autoload :Descriptor,       "refresh_sync/surfaces"
  autoload :SurfaceObservation, "refresh_sync/surfaces"
  autoload :Viewer,           "refresh_sync/surfaces"
  autoload :Surface,          "refresh_sync/surfaces"
  autoload :SurfaceRegistry,  "refresh_sync/surfaces"
  autoload :Coercion,         "refresh_sync/coercion"
  autoload :ActiveRecordStore, "refresh_sync/persistence"
  autoload :ActiveRecordSurfaceRegistry, "refresh_sync/persistence"
  autoload :DbClaimer,        "refresh_sync/persistence"
  autoload :Health,           "refresh_sync/health"

  Change = Struct.new(:table, :id, :kind, :old_attrs, :new_attrs, keyword_init: true)
  # kind: :insert, :update, :delete, :table (bulk/raw write, row identity unknown)

  class << self
    attr_writer :store, :debouncer, :registry
    attr_accessor :viewer_resolver     # ->(request) { Viewer | nil }
    attr_writer :identity_columns, :deploy_key, :require_role_diversity, :renderer_class

    def store = @store ||= MemoryStore.new
    def debouncer = @debouncer ||= Debouncer.new
    def registry = @registry ||= SurfaceRegistry.new

    def identity_columns = @identity_columns ||= %w[user_id]
    def deploy_key = @deploy_key ||= "deploy-1"
    def require_role_diversity = @require_role_diversity.nil? ? true : @require_role_diversity
    def renderer_class = @renderer_class ||= ActionController::Base

    def stats = @stats ||= Hash.new(0)
    def reset_stats! = @stats = Hash.new(0)

    def watching?(table) = store.watching?(table)

    # Entry point for every observed committed write. Routes each affected
    # cohort to Tier S (a shared surface covers the changed table and is
    # promoted) or Tier P (debounced refresh).
    def report_change(change)
      return unless watching?(change.table)
      stats[:writes_analyzed] += 1

      # A write committed during a captured GET carries that GET's request
      # id; the refresh tag is stamped with it so Turbo's native client-side
      # guard breaks the GET -> write -> refresh -> GET loop on the origin
      # tab. Writes from POST boundaries carry nil: the origin tab is just
      # another subscriber and receives the refresh like everyone else.
      origin_request_id = Recording.current&.request_id

      refresh_streams = Set.new
      touched_surfaces = Set.new
      store.matching_cohorts(change).each do |cohort|
        covering = cohort.surfaces.filter_map do |name|
          surface = registry.lookup(name)
          surface if surface && surface.tables.include?(change.table)
        end
        covering.each { |s| touched_surfaces << s }
        # Tier S only when a promoted surface covers the change; otherwise
        # this cohort falls back to a Tier P refresh.
        refresh_streams << cohort.stream unless covering.any?(&:shared?)
      end

      touched_surfaces.each do |surface|
        # Every covering write advances the surface's evidence generation —
        # even while :observing — so digests from before and after a data
        # change are never compared against each other (that would produce
        # false identity pins whenever a write lands between two viewers).
        surface.bump_generation
        if surface.shared?
          # Schedule by KEY, not by hydrated object: the closure rehydrates
          # through this process's registry at dispatch time, so a demotion
          # persisted by any process between schedule and fire is seen.
          # (A closure-captured surface holds a stale :shared status — the
          # cross-process demotion race.)
          scheduling_registry = registry
          name = surface.name
          deploy_key = surface.deploy_key
          debouncer.schedule("surface:#{surface.key}", kind: :broadcast) do
            scheduling_registry.lookup(name, deploy_key: deploy_key)&.broadcast!
          end
        end
      end
      refresh_streams.each { |stream| debouncer.schedule(stream, request_id: origin_request_id) }
    end

    def report_bulk(table)
      report_change(Change.new(table: table, kind: :table))
    end

    def install!
      Hooks.install!
      Ambient.install!
    end
  end
end
