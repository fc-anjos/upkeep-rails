module RefreshSync
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
    COLLECTOR_KEY = :refresh_sync_row_identity_collector

    Collector = Struct.new(:table, :primary_key, :ids)

    @capability = {}
    @hooked = {}
    @mutex = Mutex.new

    class << self
      # Runs a bulk write with id collection armed for `relation`'s table.
      # Yields the collector; after the block, collector.ids holds the exact
      # changed ids when the adapter hook engaged, else stays empty.
      def collecting(relation)
        klass = relation.klass
        adapter_class = klass.connection_pool.with_connection { |c| arm!(c) }
        prev = Thread.current[COLLECTOR_KEY]
        collector = Collector.new(klass.table_name, klass.primary_key, [])
        collector = nil unless collector.primary_key.is_a?(String) && capable?(adapter_class)
        Thread.current[COLLECTOR_KEY] = collector
        [yield, collector&.ids || []]
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
              RefreshSync.stats[:row_identity_unavailable] += 1
              ActiveSupport::Notifications.instrument(
                "row_identity_unavailable.refresh_sync",
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
          connection.execute("CREATE TEMPORARY TABLE refresh_sync_probe (id integer)")
          connection.exec_query("UPDATE refresh_sync_probe SET id = id WHERE 1=0 RETURNING id")
          connection.exec_query("DELETE FROM refresh_sync_probe WHERE 1=0 RETURNING id")
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
        rewritten = _refresh_sync_returning(sql)
        return super unless rewritten
        _refresh_sync_collect(rewritten, name, binds)
      end

      def exec_delete(sql, name = nil, binds = [])
        rewritten = _refresh_sync_returning(sql)
        return super unless rewritten
        _refresh_sync_collect(rewritten, name, binds)
      end

      private

      def _refresh_sync_returning(sql)
        collector = RowIdentity.current_collector
        return nil unless collector
        return nil if sql.match?(/\breturning\b/i)
        match = TARGET_SQL.match(sql)
        return nil unless match && match[1] == collector.table
        "#{sql} RETURNING #{quote_column_name(collector.primary_key)}"
      end

      def _refresh_sync_collect(sql, name, binds)
        result = internal_exec_query(sql, name, binds)
        RowIdentity.current_collector.ids.concat(result.rows.map(&:first))
        result.length
      end
    end
  end
end
