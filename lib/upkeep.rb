require "active_support"
require "active_support/core_ext"
require "upkeep/version"

# Upkeep: minimal proof of the from-scratch upkeep design.
#   - read sets recorded from execution (loaded ids + simple where predicates)
#   - coarse write matching (id overlap / predicate / table-level fallback)
#   - two-tier delivery:
#       Tier P (default): debounced Turbo 8 page refresh per cohort
#       Tier S (earned):  one scrubbed shared render broadcast per surface
#     Identity fails closed; freshness fails open.
module Upkeep
  autoload :ReadSet,          "upkeep/read_set"
  autoload :Recording,        "upkeep/recording"
  autoload :RelationAnalysis, "upkeep/relation_analysis"
  autoload :MemoryStore,      "upkeep/memory_store"
  autoload :Debouncer,        "upkeep/debouncer"
  autoload :Hooks,            "upkeep/hooks"
  autoload :Capture,          "upkeep/capture"
  autoload :SurfaceHelper,    "upkeep/capture"
  autoload :Ambient,          "upkeep/ambient"
  autoload :SharedRender,     "upkeep/shared_render"
  autoload :Descriptor,       "upkeep/surfaces"
  autoload :SurfaceObservation, "upkeep/surfaces"
  autoload :Viewer,           "upkeep/surfaces"
  autoload :Surface,          "upkeep/surfaces"
  autoload :SurfaceRegistry,  "upkeep/surfaces"
  autoload :Coercion,         "upkeep/coercion"
  autoload :ActiveRecordStore, "upkeep/persistence"
  autoload :ActiveRecordSurfaceRegistry, "upkeep/persistence"
  autoload :DbClaimer,        "upkeep/persistence"
  autoload :Health,           "upkeep/health"
  autoload :Provenance,       "upkeep/provenance"
  autoload :FragmentCache,    "upkeep/fragment_cache"
  autoload :Streams,          "upkeep/streams"
  autoload :RowIdentity,      "upkeep/row_identity"
  autoload :AutoSurfaces,     "upkeep/auto_surfaces"
  autoload :Verdict,          "upkeep/verdict"
  autoload :Dispatch,         "upkeep/dispatch"

  # One observed committed write.
  #   kind: :insert, :update, :delete - one row, full attrs known
  #         :bulk_rows               - exact row ids known; `op` says which
  #                                    write (:update/:delete/:insert/:upsert);
  #                                    `rows` may carry projected after-attrs
  #                                    ({id => {column => value}}, RETURNING)
  #         :table                   - bulk/raw write, row identity unknown
  # columns: changed column names when statically known (update_all SET keys,
  # previous_changes); nil means "assume all columns" (safe coarseness).
  # An unknowable before-state is an honest first-class :unknown that flows
  # through verdicts conservatively — it never raises and never vanishes.
  Fact = Struct.new(:table, :id, :kind, :op, :old_attrs, :new_attrs,
                    :columns, :ids, :rows, keyword_init: true) do
    def operation
      op || (kind == :bulk_rows || kind == :table ? nil : kind)
    end

    def row_ids = ids || (id.nil? ? [] : [id])

    # Uniform row view for verdict evaluation: attrs are a Hash when known,
    # :unknown when the row exists on that side but its values do not ride
    # the fact, :absent when the row does not exist on that side. A
    # row-level fact with no id still describes one row — of unknown
    # identity — and must flow through conservatively, never vanish.
    def each_row
      identities = row_ids.empty? ? [nil] : row_ids
      identities.map { |rid| { id: rid, before: before_state, after: after_state(rid) } }
    end

    private

    def before_state
      case operation
      when :insert then :absent
      when :update, :delete then old_attrs || :unknown
      else :unknown
      end
    end

    def after_state(rid)
      case operation
      when :delete then :absent
      when nil then :unknown
      else new_attrs || rows&.dig(rid) || :unknown
      end
    end
  end
  Change = Fact

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

    # Tier S transport payload limit in bytes (nil = unlimited). Real cable
    # adapters have hard caps — Postgres LISTEN/NOTIFY tops out at 8KB — so
    # an oversized shared payload degrades THAT delivery to a refresh, loudly.
    attr_writer :payload_limit
    def payload_limit = @payload_limit

    # Test seam: called on the dispatcher thread between the scrubbed render
    # and the store-side dispatch claim — the narrowed demotion-race window.
    # Production leaves it nil.
    attr_accessor :dispatch_interlock

    # Infrastructure tables whose writes never become change events: our own
    # tables (a cohort insert must not trigger cohort matching), session
    # storage written on every request, audit/versioning echo writes, Rails
    # bookkeeping. This is an INFRASTRUCTURE list, not a performance dial —
    # if an active cohort actually depends on an ignored table, every
    # skipped write emits a loud warning instead of silently going stale.
    DEFAULT_IGNORED_TABLES = %w[
      upkeep_cohorts upkeep_surfaces upkeep_claims
      upkeep_cohort_tables
      schema_migrations ar_internal_metadata sessions
      active_storage_blobs active_storage_attachments active_storage_variant_records
      audits versions
    ].freeze

    attr_writer :ignored_tables
    def ignored_tables = @ignored_tables ||= DEFAULT_IGNORED_TABLES.dup.to_set
    def ignored_table?(table) = ignored_tables.include?(table)

    def stats = @stats ||= Hash.new(0)
    def reset_stats! = @stats = Hash.new(0)

    # Emergency kill switch (ops escape hatch, normally never set): forces
    # refresh-only delivery even for promoted surfaces, for the case where
    # the demotion machinery itself is buggy. NOT a configuration surface —
    # the sole gate for shared delivery is the promotion evidence bar.
    def region_broadcast_disabled? = ENV["UPKEEP_DISABLE_REGION_BROADCAST"] == "1"

    # Rails owns "did this durably happen": on 7.2+ a block deferred here
    # runs after the outermost transaction commits and is discarded on
    # rollback. On 7.1 (no public API) the block runs immediately — a
    # rolled-back write then costs one spurious refresh, which is the safe
    # direction (freshness fails open).
    def defer_to_commit(&block)
      if ActiveRecord.respond_to?(:after_all_transactions_commit)
        ActiveRecord.after_all_transactions_commit(&block)
      else
        yield
      end
    end

    def watching?(table) = store.watching?(table)

    # Entry point for every observed committed write. Verdict-driven
    # routing: each affected cohort goes to Tier S (a promoted surface
    # covers the change for that member) or Tier P (debounced refresh),
    # carrying the fact's verdict so provably unnecessary refreshes can be
    # netted out inside the debounce window.
    def report_change(change)
      return report_ignored_write(change) if ignored_table?(change.table)
      return unless watching?(change.table)
      stats[:writes_analyzed] += 1
      Dispatch.new(change).call
    end

    # Misuse detector: an ignored table some ACTIVE cohort depends on means
    # pages are silently going stale — warn loudly, still skip.
    def report_ignored_write(change)
      return unless watching?(change.table)
      stats[:ignored_writes_warned] += 1
      ActiveSupport::Notifications.instrument(
        "ignored_table_write_skipped.upkeep",
        table: change.table, watched: true
      )
    end

    def report_bulk(table, ids: nil, columns: nil, rows: nil, op: nil)
      kind = ids ? :bulk_rows : :table
      report_change(Fact.new(table: table, kind: kind, ids: ids,
                             columns: columns, rows: rows, op: op))
    end

    def region_span(surface) = surface.region_addresses

    # Registration suppression: cohorts must never register for requests
    # that have no browser behind them (Pulse's chatbot drives controllers
    # through in-process integration sessions from Sidekiq jobs, logged in
    # as real users). Write CAPTURE stays global — only registration stops.
    SUPPRESS_KEY = :upkeep_suppress_registration

    def suppress_registration
      prev = Thread.current[SUPPRESS_KEY]
      Thread.current[SUPPRESS_KEY] = true
      yield
    ensure
      Thread.current[SUPPRESS_KEY] = prev
    end

    def registration_suppressed? = !!Thread.current[SUPPRESS_KEY]

    def install!
      return if @installed
      @installed = true
      Hooks.install!
      Ambient.install!
      AutoSurfaces.install!
      FragmentCache.install!
      Streams.attach! if defined?(::Turbo)
      # Anything executed by an Active Job is job context: suppress cohort
      # registration for its whole duration (perform_now included).
      ActiveSupport.on_load(:active_job) do
        ActiveJob::Base.around_perform do |_job, block|
          Upkeep.suppress_registration(&block)
        end
      end
    end
  end
end

require "upkeep/railtie" if defined?(::Rails::Railtie)
