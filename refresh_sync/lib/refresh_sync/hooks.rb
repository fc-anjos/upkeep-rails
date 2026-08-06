module RefreshSync
  # All runtime instrumentation. Read-side hooks no-op unless a Recording is
  # active on the current thread; write-side hooks no-op unless some cohort
  # watches the written table.
  module Hooks
    # Read side: relations that execute while capturing.
    module RelationObserver
      def exec_queries(&block)
        recording = Recording.current
        return super unless recording
        records = recording.accounting { super }
        recording.record_relation(self)
        records
      end
    end

    # Read side: the ActiveRecord read doors that never materialize records
    # and so bypass exec_queries entirely. All hooked at the Relation level
    # on structured data (the relation's own where clause) — never SQL text.
    #   calculate  — count/sum/average/minimum/maximum
    #   pluck      — also covers pick and ids (both delegate to pluck)
    #   exists?    — including the conditions-argument forms
    module RelationReadDoors
      def calculate(operation, column_name)
        recording = Recording.current
        return super unless recording
        result = recording.accounting { super }
        recording.record_relation(self)
        result
      end

      def pluck(*column_names)
        recording = Recording.current
        return super unless recording
        result = recording.accounting { super }
        recording.record_relation(self)
        result
      end

      def exists?(conditions = :none)
        recording = Recording.current
        return super unless recording
        result = recording.accounting { super }
        relation =
          case conditions
          when :none, nil, true then self
          when Hash then where(conditions)
          when String, Array then nil # SQL-ish conditions: not analyzable
          else where(klass.primary_key => conditions)
          end
        if relation
          recording.record_relation(relation)
        else
          recording.read_set.record_table(
            klass.table_name, :exists_with_opaque_conditions, node: recording.prov_address
          )
        end
        result
      end
    end

    # Read side: statement-cache executions (Model.find, cached find_by,
    # association loads) bypass Relation#exec_queries; the bind map carries
    # the structured predicate. When the cache exposes no klass/bind_map,
    # the query is deliberately left unaccounted so the audit flags it
    # instead of silently claiming coverage.
    module StatementCacheObserver
      def execute(params, connection, **kwargs, &block)
        recording = Recording.current
        return super unless recording
        # Rails 8.1 renamed the ivar @klass -> @model; support both.
        model = instance_variable_get(:@model) || instance_variable_get(:@klass)
        bind_map = instance_variable_get(:@bind_map)
        return super unless model && bind_map
        result = recording.accounting { super }
        recording.record_statement_cache(model, bind_map.bind(params))
        result
      end
    end

    # Read side: any record materialized from the DB. Rails 8.1 routes every
    # materialization path (Relation#exec_queries, Model.find, warm statement
    # caches) through instantiate_instance_of — NOT through instantiate,
    # which never fires. Internal API; must be re-verified per Rails version.
    module InstantiateObserver
      def instantiate_instance_of(...)
        record = super
        Recording.current&.record_instance(record)
        record
      end
    end

    # Read side: attribute reads during capture, used ONLY to verify
    # per-iteration node identity (reading a row other than the one bound to
    # the open loop instance voids row targeting for that node — identity
    # fails closed). No-ops on a nil thread-local outside capture windows.
    # `_read_attribute` is the single choke point every generated attribute
    # reader funnels through — internal API, re-verify per Rails version.
    module AttributeReadObserver
      def _read_attribute(attr_name, &block)
        if (recording = Recording.current)
          pk = self.class.primary_key
          if pk.is_a?(String) && attr_name.to_s != pk
            recording.note_attribute_read(self.class.table_name, super(pk))
          end
        end
        super
      end
    end

    # Write side: per-row committed changes.
    module WriteObserver
      extend ActiveSupport::Concern

      included do
        after_commit :_refresh_sync_report_write, on: [:create, :update, :destroy]
      end

      private

      def _refresh_sync_report_write
        table = self.class.table_name
        return unless RefreshSync.watching?(table)

        change =
          if destroyed?
            Change.new(table: table, id: id, kind: :delete, old_attrs: attributes)
          elsif previously_new_record?
            Change.new(table: table, id: id, kind: :insert, new_attrs: attributes)
          else
            old_attrs = attributes.merge(previous_changes.transform_values(&:first))
            Change.new(table: table, id: id, kind: :update, old_attrs: old_attrs, new_attrs: attributes)
          end
        RefreshSync.report_change(change)
      end
    end

    # Write side: bulk writes that skip callbacks.
    module BulkWriteObserver
      def update_all(...)
        result = super
        RefreshSync.report_bulk(klass.table_name)
        result
      end

      def delete_all(...)
        result = super
        RefreshSync.report_bulk(klass.table_name)
        result
      end
    end

    RAW_WRITE_SQL = /\A\s*(insert\s+into|update|delete\s+from)\s+["`']?(\w+)/i

    # Completeness audit: a SELECT that executes during a capture with no
    # read door accounting for it is a dependency the read set cannot see.
    # Statement-kind guard only — dependencies are never derived from SQL
    # text; attribution uses ActiveRecord's structured "Model Action" query
    # name convention.
    AUDIT_READ_SQL = /\A\s*(select|with)\b/i
    AUDIT_IGNORED_NAMES = ["SCHEMA", "EXPLAIN", "TRANSACTION"].freeze

    def self.attributable_table(name)
      return nil unless name.is_a?(String)
      first_word = name.split(" ").first
      return nil unless first_word&.match?(/\A[A-Z]/)
      klass = first_word.safe_constantize
      return nil unless klass.is_a?(Class) && klass < ActiveRecord::Base
      table = klass.table_name
      Recording::OWN_TABLES.include?(table) ? nil : table
    end

    def self.audit_unaccounted_read(recording, payload)
      if (table = attributable_table(payload[:name]))
        # Conservative degrade: whatever is attributable becomes a
        # table-level dependency — every write to that table now matches.
        recording.read_set.record_table(table, :unhooked_read_door,
                                        node: recording.prov_address)
        RefreshSync.stats[:unhooked_reads_degraded] += 1
        ActiveSupport::Notifications.instrument(
          "capture_incomplete.refresh_sync",
          mode: :degraded_table_level, table: table, query_name: payload[:name]
        )
      else
        # Unattributable: the capture refuses precision entirely (no cohort
        # registration). Silent partial liveness would be a stale-page lie.
        recording.incomplete!(payload[:name] || "unnamed query")
        ActiveSupport::Notifications.instrument(
          "capture_incomplete.refresh_sync",
          mode: :unattributable, query_name: payload[:name]
        )
      end
    end

    def self.install!
      return if @installed
      @installed = true

      ActiveRecord::Relation.prepend(RelationObserver)
      ActiveRecord::Relation.prepend(RelationReadDoors)
      # (Ambient choke points are installed separately via Ambient.install!)
      ActiveRecord::Relation.prepend(BulkWriteObserver)
      ActiveRecord::StatementCache.prepend(StatementCacheObserver)
      ActiveRecord::Base.singleton_class.prepend(InstantiateObserver)
      ActiveRecord::Base.prepend(AttributeReadObserver)
      ActiveRecord::Base.include(WriteObserver)

      ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        payload = event.payload
        recording = Recording.current
        if recording && !recording.accounting? &&
           !AUDIT_IGNORED_NAMES.include?(payload[:name]) &&
           AUDIT_READ_SQL.match?(payload[:sql])
          audit_unaccounted_read(recording, payload)
        end
      end

      # Raw SQL safety net: writes issued via execute/exec_query carry no
      # model name; degrade them to a table-level change. Detection is
      # heuristic, but a false positive only costs an extra page refresh —
      # refresh delivery makes double-detection harmless.
      ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        payload = event.payload
        name = payload[:name]
        next unless name.nil? || name == "SQL"
        if (match = RAW_WRITE_SQL.match(payload[:sql]))
          table = match[2]
          RefreshSync.report_bulk(table) if RefreshSync.watching?(table)
        end
      end
    end
  end
end
