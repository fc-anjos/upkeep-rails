require "digest"

module RefreshSync
  # Thread-local capture window. All observation hooks are gated on
  # Recording.current being non-nil, so an app with no captured request in
  # flight pays only a thread-local nil check.
  class Recording
    KEY = :refresh_sync_recording

    def self.current = Thread.current[KEY]

    def self.start
      Thread.current[KEY] = new
    end

    def self.finish
      Thread.current[KEY] = nil
    end

    attr_reader :read_set, :ambient, :surfaces

    def initialize
      @read_set = ReadSet.new
      @ambient = Set.new         # reasons: :session_read, :cookie_read, ...
      @identity_bound = false
      @surfaces = []
    end

    def ambient!(reason)
      @ambient << reason
    end

    def identity_bound!
      @identity_bound = true
    end

    def identity_bound? = @identity_bound

    # Every AR record materialized from the database.
    def record_instance(record)
      @read_set.record_id(record.class.table_name, record.id)
    end

    # A relation that just executed: extract simple membership predicates,
    # degrade to table-level with a reason when analysis can't be exact.
    def record_relation(relation)
      RefreshSync.stats[:relations_analyzed] += 1
      RelationAnalysis.new(relation).apply_to(self)
    end

    # A shared_surface region rendered during this capture.
    def record_surface(name:, partial:, locals:, html:)
      descriptor = Descriptor.new(name: name, partial: partial, locals: locals)
      @surfaces << SurfaceObservation.new(
        descriptor: descriptor,
        digest: Digest::SHA256.hexdigest(html)
      )
    end
  end
end
