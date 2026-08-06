module Upkeep
  # Exact row identity for bulk writes (update_all / delete_all), database-
  # agnostically. Rails discards the raw result of a bulk statement, so the
  # changed row ids are normally unknowable — the blunt fallback treats the
  # write as table-level. Where the database itself can answer, we ask it:
  # append " RETURNING <pk>" to the statement (the same post-Arel string
  # append Rails uses for insert returning — Arel has no RETURNING node) and
  # read the ids back through the adapter-agnostic Result path.
  #
  # Capability is decided by a boot-time EVIDENCE PROBE, not an adapter
  # catalog: a no-op UPDATE/DELETE ... RETURNING runs against a temporary
  # table inside a rolled-back transaction on the live connection; the
  # database's own answer (per concrete adapter class) is cached. Probe
  # failure means today's blunt behavior plus a loud degrade warning.
  module RowIdentity
    COLLECTOR_KEY = :upkeep_row_identity_collector

    # Beyond the primary key, the RETURNING clause also projects the
    # columns that appear in registered cohort predicates for the table
    # (bounded, derived from stored read-set evidence — never configured),
    # so bulk facts carry per-row after-values and the verdict layer can
    # prove writes irrelevant instead of conservatively refreshing.
    MAX_PROJECTED_COLUMNS = 8

    Collector = Struct.new(:table, :primary_key, :ids, :projected, :rows)

    @capability = {}
    @hooked = {}
    @mutex = Mutex.new

    class << self
      # Runs a bulk write with id collection armed for `relation`'s table.
      # After the block: ids holds the exact changed ids when the adapter
      # hook engaged (else stays empty), rows the projected after-values.
      def collecting(relation)
        klass = relation.klass
        adapter_class = klass.connection_pool.with_connection { |c| arm!(c) }
        prev = Thread.current[COLLECTOR_KEY]
        collector = Collector.new(klass.table_name, klass.primary_key, [],
                                  projected_columns(klass), {})
        collector = nil unless collector.primary_key.is_a?(String) && capable?(adapter_class)
        Thread.current[COLLECTOR_KEY] = collector
        [yield, collector&.ids || [], collector&.rows || {}]
      ensure
        Thread.current[COLLECTOR_KEY] = prev
      end

      def current_collector = Thread.current[COLLECTOR_KEY]

      def capable?(adapter_class) = !!@capability[adapter_class]

      # Test seam.
      def reset!
        @capability = {}
      end

      private

      # Predicate-relevant columns for the table, validated against the
      # model's real columns (so the extended RETURNING can never produce a
      # SQL error plain-pk RETURNING would not). Deterministically bounded:
      # a page whose predicates reference more than the cap keeps id-only
      # collection — unprojected columns stay unknown, which is the normal
      # conservative path, not a degradation.
      def projected_columns(klass)
        store = Upkeep.store
        return [] unless store.respond_to?(:predicate_columns)
        columns = store.predicate_columns(klass.table_name) - [klass.primary_key]
        columns.select { |c| klass.column_names.include?(c) }
               .sort.first(MAX_PROJECTED_COLUMNS)
      end

      # Prepend the hook on the CONCRETE adapter class of the live
      # connection (adapters override exec_update/exec_delete, so the
      # abstract layer never sees the call) and probe it. The class is
      # discovered at runtime — no adapter name catalog. Returns the class.
      def arm!(connection)
        adapter_class = connection.class
        @mutex.synchronize do
          unless @hooked[adapter_class]
            adapter_class.prepend(AdapterHook)
            @hooked[adapter_class] = true
          end
          unless @capability.key?(adapter_class)
            @capability[adapter_class] = probe(connection)
            unless @capability[adapter_class]
              Upkeep.stats[:row_identity_unavailable] += 1
              ActiveSupport::Notifications.instrument(
                "row_identity_unavailable.upkeep",
                adapter: adapter_class.name,
                consequence: :bulk_writes_match_table_level
              )
            end
          end
        end
        adapter_class
      end

      # The database answers for itself: can this connection run
      # UPDATE/DELETE ... RETURNING? Any failure — syntax error, DDL
      # restrictions, ancient server — means no.
      def probe(connection)
        connection.transaction(requires_new: true) do
          connection.execute("CREATE TEMPORARY TABLE upkeep_probe (id integer)")
          connection.exec_query("UPDATE upkeep_probe SET id = id WHERE 1=0 RETURNING id")
          connection.exec_query("DELETE FROM upkeep_probe WHERE 1=0 RETURNING id")
          raise ActiveRecord::Rollback
        end
        true
      rescue StandardError
        false
      end
    end

    # Prepended on the concrete adapter class. Engages only while a
    # collector is armed for the statement's own table; every other
    # statement passes straight through.
    module AdapterHook
      TARGET_SQL = /\A\s*(?:update|delete\s+from)\s+["`']?([A-Za-z0-9_]+)/i

      def exec_update(sql, name = nil, binds = [])
        rewritten = _upkeep_returning(sql)
        return super unless rewritten
        _upkeep_collect(rewritten, name, binds)
      end

      def exec_delete(sql, name = nil, binds = [])
        rewritten = _upkeep_returning(sql)
        return super unless rewritten
        _upkeep_collect(rewritten, name, binds)
      end

      private

      def _upkeep_returning(sql)
        collector = RowIdentity.current_collector
        return nil unless collector
        return nil if sql.match?(/\breturning\b/i)
        match = TARGET_SQL.match(sql)
        return nil unless match && match[1] == collector.table
        columns = [collector.primary_key, *collector.projected]
        "#{sql} RETURNING #{columns.map { |c| quote_column_name(c) }.join(', ')}"
      end

      def _upkeep_collect(sql, name, binds)
        result = internal_exec_query(sql, name, binds)
        collector = RowIdentity.current_collector
        result.rows.each do |row|
          collector.ids << row.first
          if collector.projected.any?
            collector.rows[row.first] = collector.projected.zip(row.drop(1)).to_h
          end
        end
        result.length
      end
    end
  end
end
