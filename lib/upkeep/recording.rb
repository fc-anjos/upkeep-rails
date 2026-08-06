require "digest"

module Upkeep
  # Thread-local capture window. All observation hooks are gated on
  # Recording.current being non-nil, so an app with no captured request in
  # flight pays only a thread-local nil check.
  class Recording
    KEY = :upkeep_recording

    def self.current = Thread.current[KEY]

    def self.start(request_id: nil)
      Thread.current[KEY] = new(request_id: request_id)
    end

    def self.finish
      Thread.current[KEY] = nil
    end

    attr_reader :read_set, :ambient, :surfaces, :request_id

    def initialize(request_id: nil)
      @request_id = request_id
      @read_set = ReadSet.new
      @ambient = Set.new         # reasons: :session_read, :cookie_read, ...
      @identity_bound = false
      @surfaces = []
    end

    # Render trace for provenance (node addresses); built lazily so captures
    # of uninstrumented pages pay nothing.
    def prov
      @prov ||= Provenance::Trace.new(iteration_ids: method(:iteration_ids))
    end

    # Current node address without forcing a Trace into existence.
    def prov_address
      @prov&.current_address
    end

    # Upkeep's own bookkeeping tables: reads of these during a capture
    # (store lookups on a GET-boundary write path) must never become page
    # dependencies — a page depending on the cohort table is a feedback
    # loop, not a data dependency. Distinct from the user-facing ignore
    # list, whose tables ARE recorded so the misuse detector can warn.
    OWN_TABLES = %w[upkeep_cohorts upkeep_surfaces upkeep_claims
                    upkeep_cohort_tables].freeze

    # --- read-door accounting (capture-completeness audit) -----------------
    # Every hooked read door wraps its query execution in `accounting`; the
    # sql.active_record audit subscriber treats a SELECT executed during
    # capture OUTSIDE any accounting window as an unhooked read door.

    def accounting
      @accounting_depth = (@accounting_depth || 0) + 1
      yield
    ensure
      @accounting_depth -= 1
    end

    def accounting? = (@accounting_depth || 0).positive?

    # An unattributable unaccounted read: the capture cannot vouch for its
    # own completeness and refuses precision (no cohort is registered).
    def incomplete!(detail)
      @incomplete = detail
    end

    def incomplete? = !!@incomplete
    def incomplete_detail = @incomplete

    def ambient!(reason)
      @ambient << reason
    end

    def identity_bound!
      @identity_bound = true
    end

    def identity_bound? = @identity_bound

    # Every AR record materialized from the database. Node address (when a
    # provenance-instrumented template node is open) rides along as metadata.
    def record_instance(record)
      table = record.class.table_name
      return if OWN_TABLES.include?(table)
      @read_set.record_id(table, record.id, node: @prov&.current_address)
    end

    # The read-set side of per-iteration identity: [table, ordered ids]
    # materialized under `node_address`, but only when exactly one table
    # did — ambiguity yields nil and the iteration keeps the plain address.
    # Ids arrive in relation-result order (Set preserves insertion order).
    def iteration_ids(node_address)
      return nil unless node_address
      candidates = @read_set.tables.filter_map do |table, deps|
        node = deps.node_reads[node_address]
        [table, node.ids.to_a] if node && node.ids.any?
      end
      candidates.size == 1 ? candidates.first : nil
    end

    # Attribute-read evidence (loop identity verification). Forwarded to the
    # trace only when one exists — uninstrumented captures pay nothing.
    def note_attribute_read(table, id)
      @prov&.note_attribute_read(table, id)
    end

    # A relation that just executed: extract simple membership predicates,
    # degrade to table-level with a reason when analysis can't be exact.
    def record_relation(relation, membership_only: false)
      return if OWN_TABLES.include?(relation.klass.table_name)
      Upkeep.stats[:relations_analyzed] += 1
      RelationAnalysis.new(relation).apply_to(self, membership_only: membership_only)
    end

    # A statement-cache execution (Model.find / find_by / association
    # loads): the cache's bind map IS the structured predicate — each bound
    # attribute is an equality on the cached query's own table. Bind names
    # that are not columns (LIMIT/OFFSET) are dropped, which only widens
    # the predicate (over-match is the safe direction). Closes the
    # nil-result hole: a find_by that returned nothing still records the
    # predicate, so the row's later INSERT matches.
    def record_statement_cache(klass, bound_attributes)
      table = klass.table_name
      return if OWN_TABLES.include?(table)
      Upkeep.stats[:statement_caches_analyzed] += 1
      columns = klass.column_names
      predicate = {}
      bound_attributes.each do |attr|
        name = attr.name.to_s
        next unless columns.include?(name)
        (predicate[name] ||= []) << attr.value_before_type_cast
      end
      @read_set.record_predicate(table, predicate, node: @prov&.current_address)
      identity_bound! if (predicate.keys & Upkeep.identity_columns).any?
    end

    # A shared_surface region rendered during this capture. Node digests are
    # the per-node evidence for region-level promotion; node texts carry the
    # data-rs-node stamps that mark broadcastable regions.
    def record_surface(name:, partial:, locals:, html:, node_digests: {}, node_texts: {})
      descriptor = Descriptor.new(name: name, partial: partial, locals: locals)
      @surfaces << SurfaceObservation.new(
        descriptor: descriptor,
        digest: Digest::SHA256.hexdigest(html),
        node_digests: node_digests,
        node_texts: node_texts
      )
    end
  end
end
