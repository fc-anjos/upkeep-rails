module Upkeep
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
        # A whole-row count sees membership only: an in-place content move
        # cannot change it. Any other aggregate (sum/min/max/avg, count of
        # a nullable column) depends on row content and stays a full
        # predicate dependency.
        recording.record_relation(
          self, membership_only: _upkeep_membership_count?(operation, column_name)
        )
        _upkeep_record_columns(recording, [column_name])
        result
      end

      def pluck(*column_names)
        recording = Recording.current
        return super unless recording
        result = recording.accounting { super }
        recording.record_relation(self)
        _upkeep_record_columns(recording, column_names)
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
          # exists? sees membership only, never row content.
          recording.record_relation(relation, membership_only: true)
        else
          recording.read_set.record_table(
            klass.table_name, :exists_with_opaque_conditions, node: recording.prov_address
          )
        end
        result
      end

      private

      def _upkeep_membership_count?(operation, column_name)
        return false unless operation.to_s == "count"
        column_name.nil? || column_name == :all ||
          column_name.to_s == "*" || column_name.to_s == klass.primary_key
      end

      # Plain column names from a pluck/calculate column list; Arel nodes
      # and star are skipped (missing column evidence only widens, never
      # narrows — absence means "assume all columns").
      def _upkeep_record_columns(recording, column_names)
        table = klass.table_name
        return if Recording::OWN_TABLES.include?(table)
        column_names.each do |column|
          next unless column.is_a?(Symbol) || column.is_a?(String)
          name = column.to_s
          recording.read_set.record_column(table, name) if klass.column_names.include?(name)
        end
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
          table = self.class.table_name
          pk = self.class.primary_key
          if pk.is_a?(String) && attr_name.to_s != pk
            recording.note_attribute_read(table, super(pk))
            # Column-read evidence: which columns this render actually
            # consumed. Used only to refine member-divergence ejection.
            recording.read_set.record_column(table, attr_name) unless Recording::OWN_TABLES.include?(table)
          end
        end
        super
      end
    end

    # Write side: per-row committed changes.
    module WriteObserver
      extend ActiveSupport::Concern

      included do
        after_commit :_upkeep_report_write, on: [:create, :update, :destroy]
      end

      private

      def _upkeep_report_write
        table = self.class.table_name
        return unless Upkeep.watching?(table)

        change =
          if destroyed?
            Change.new(table: table, id: id, kind: :delete, old_attrs: attributes)
          elsif previously_new_record?
            Change.new(table: table, id: id, kind: :insert, new_attrs: attributes)
          else
            old_attrs = attributes.merge(previous_changes.transform_values(&:first))
            Change.new(table: table, id: id, kind: :update, old_attrs: old_attrs,
                       new_attrs: attributes, columns: previous_changes.keys)
          end
        Upkeep.report_change(change)
      end
    end

    # Write side: bulk writes that skip callbacks. The adapter-level
    # RowIdentity hook (RETURNING, capability-probed) turns them into
    # exact-id changes where the database can answer; otherwise they stay
    # table-level. The statement's own return value is the affected count —
    # zero affected rows means nothing changed and nothing is reported.
    # Reports are deferred to the outermost commit (a rolled-back bulk
    # write must not refresh anyone).
    module BulkWriteObserver
      def update_all(updates)
        table = klass.table_name
        return super unless Upkeep.watching?(table)
        result, ids, rows = RowIdentity.collecting(self) { super }
        return result if result == 0
        columns = _upkeep_set_columns(updates)
        Upkeep.defer_to_commit do
          Upkeep.report_bulk(table, ids: ids.presence, columns: columns,
                                  rows: rows.presence, op: :update)
        end
        result
      end

      def delete_all
        table = klass.table_name
        return super unless Upkeep.watching?(table)
        result, ids, = RowIdentity.collecting(self) { super }
        return result if result == 0
        Upkeep.defer_to_commit do
          Upkeep.report_bulk(table, ids: ids.presence, op: :delete)
        end
        result
      end

      private

      # SET columns are statically visible for hash assignments (plus the
      # auto-added locking column). A raw-string SET
      # ("position = position + 1") is parsed — once per shape, via the
      # capped SqlAnalysis cache — into its assigned column list; a parse
      # failure keeps nil = assume all columns, the safe coarseness.
      def _upkeep_set_columns(updates)
        columns =
          case updates
          when Hash then updates.keys.map(&:to_s)
          when String then SqlAnalysis.set_columns(klass.table_name, updates)
          end
        return nil unless columns
        columns << klass.locking_column if klass.locking_enabled?
        columns.uniq
      end
    end

    # Write side: insert_all / upsert_all. Rails already asks the database
    # for the inserted primary keys wherever it can (RETURNING by default
    # when the adapter supports insert returning) — the ids were never
    # missing, they ride the public return value. Where the database can't
    # answer (MySQL proper), degrade to table-level with a warning.
    module InsertAllObserver
      def execute
        result = super
        table = model.table_name
        if Upkeep.watching?(table) && !Upkeep.ignored_table?(table)
          pk = Array(model.primary_key).first
          ids = _upkeep_result_ids(result, pk)
          if ids.blank?
            Upkeep.stats[:insert_all_without_ids] += 1
            ActiveSupport::Notifications.instrument(
              "row_identity_unavailable.upkeep",
              adapter: :insert_returning_unsupported, table: table,
              consequence: :bulk_writes_match_table_level
            )
          end
          op = respond_to?(:update_duplicates?, true) && send(:update_duplicates?) ? :upsert : :insert
          Upkeep.defer_to_commit do
            Upkeep.report_bulk(table, ids: ids.presence, op: op)
          end
        end
        result
      end

      private

      def _upkeep_result_ids(result, pk)
        return nil unless pk && result.is_a?(ActiveRecord::Result)
        index = result.columns.index(pk)
        index && result.rows.map { |row| row[index] }
      end
    end

    RAW_WRITE_SQL = /\A\s*(insert\s+into|update|delete\s+from)\s+["`']?(\w+)/i

    # DDL and maintenance statements Rails classifies as writes but which
    # change schema, not row data: never an unattributed-write warning.
    # (The "SCHEMA" name gate below does not catch schema statements issued
    # through bare execute — observed at boot with strict mode on.)
    DDL_SQL = /\A\s*(create|drop|alter|pragma|vacuum|reindex|analyze|savepoint|release)\b/i

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
        degrade_unaccounted_read(recording, [table],
                                 reason: :unhooked_read_door, payload: payload)
      elsif (tables = parsed_query_tables(payload[:sql])) && tables.any?
        # No model name, but the parser can still name the tables read:
        # register conservative table-level dependencies instead of
        # refusing capture — liveness COARSENED, not lost. (Rule one: a
        # wrong table list here could only add refreshes; the tables the
        # statement actually read come from the parse of that statement.)
        degrade_unaccounted_read(recording, tables,
                                 reason: :unattributed_query, payload: payload)
      else
        # Even the parser cannot name a table (unparseable, or a read from
        # no table at all): the capture refuses precision entirely (no
        # cohort registration). Silent partial liveness would be a
        # stale-page lie.
        recording.incomplete!(payload[:name] || "unnamed query")
        ActiveSupport::Notifications.instrument(
          "capture_incomplete.upkeep",
          mode: :unattributable, query_name: payload[:name]
        )
      end
    end

    def self.degrade_unaccounted_read(recording, tables, reason:, payload:)
      tables.each do |table|
        recording.read_set.record_table(table, reason, node: recording.prov_address)
        Legibility.note_hint(table, reason)
      end
      Upkeep.stats[:unhooked_reads_degraded] += 1
      ActiveSupport::Notifications.instrument(
        "capture_incomplete.upkeep",
        mode: :degraded_table_level, table: tables.first, tables: tables,
        query_name: payload[:name]
      )
    end

    # Physical tables read by an unattributable statement, via the parse
    # cache; upkeep's own bookkeeping tables never become dependencies.
    def self.parsed_query_tables(sql)
      tables = SqlAnalysis.statement_tables(sql)
      tables && (tables - Recording::OWN_TABLES)
    end

    def self.install!
      return if @installed
      @installed = true

      ActiveRecord::Relation.prepend(RelationObserver)
      ActiveRecord::Relation.prepend(RelationReadDoors)
      # (Ambient choke points are installed separately via Ambient.install!)
      ActiveRecord::Relation.prepend(BulkWriteObserver)
      ActiveRecord::InsertAll.prepend(InsertAllObserver) if defined?(ActiveRecord::InsertAll)
      ActiveRecord::StatementCache.prepend(StatementCacheObserver)
      ActiveRecord::Base.singleton_class.prepend(InstantiateObserver)
      ActiveRecord::Base.prepend(AttributeReadObserver)
      ActiveRecord::Base.include(WriteObserver)

      ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        audit_sql_event(event.payload)
      end
      ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        observe_raw_sql_event(event.payload)
      end
    end

    def self.audit_sql_event(payload)
      recording = Recording.current
      return unless recording && !recording.accounting?
      return if AUDIT_IGNORED_NAMES.include?(payload[:name])
      return unless AUDIT_READ_SQL.match?(payload[:sql])
      audit_unaccounted_read(recording, payload)
    end

    # Raw SQL safety net: writes issued via execute/exec_query carry no
    # model name; degrade them to a table-level change (deferred to
    # commit). Detection is heuristic, but a false positive only costs an
    # extra page refresh — refresh delivery makes double-detection
    # harmless. Rails' own read/write classifier (write_query?, the one
    # that marks transactions dirty) cross-checks the heuristic: a
    # Rails-classified write our table extraction can't attribute is a
    # completeness warning, never a silent miss.
    def self.observe_raw_sql_event(payload)
      name = payload[:name]
      return unless name.nil? || name == "SQL"
      sql = payload[:sql]
      if (match = RAW_WRITE_SQL.match(sql))
        table = match[2]
        if Upkeep.watching?(table) && !RowIdentity.current_collector
          Upkeep.defer_to_commit { Upkeep.report_bulk(table) }
        end
      elsif unattributable_write?(payload[:connection], sql)
        # No verb catalog needed here: Rails instruments transaction
        # control as "TRANSACTION" and DDL as "SCHEMA", both already
        # excluded by this subscriber's name gate — what reaches this
        # branch is an unnamed statement Rails itself classifies as a
        # write and our table extraction could not attribute.
        Upkeep.stats[:unattributed_writes] += 1
        ActiveSupport::Notifications.instrument(
          "unattributed_write.upkeep", sql_head: sql.to_s[0, 60]
        )
      end
    end

    def self.unattributable_write?(connection, sql)
      return false if DDL_SQL.match?(sql)
      connection && connection.respond_to?(:write_query?, true) &&
        connection.send(:write_query?, sql)
    end
  end
end
