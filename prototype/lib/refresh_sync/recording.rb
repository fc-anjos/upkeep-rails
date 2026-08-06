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

    attr_reader :read_set

    def initialize
      @read_set = ReadSet.new
    end

    # Every AR record materialized from the database.
    def record_instance(record)
      @read_set.record_id(record.class.table_name, record.id)
    end

    # A relation that just executed: extract simple membership predicates,
    # degrade to table-level with a reason when analysis can't be exact.
    def record_relation(relation)
      RefreshSync.stats[:relations_analyzed] += 1
      RelationAnalysis.new(relation).apply_to(@read_set)
    end
  end
end
