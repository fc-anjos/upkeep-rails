require "digest"

module RefreshSync
  # Thread-local capture window. All observation hooks are gated on
  # Recording.current being non-nil, so an app with no captured request in
  # flight pays only a thread-local nil check.
  class Recording
    KEY = :refresh_sync_recording

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
      @read_set.record_id(record.class.table_name, record.id, node: @prov&.current_address)
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
    def record_relation(relation)
      RefreshSync.stats[:relations_analyzed] += 1
      RelationAnalysis.new(relation).apply_to(self)
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
