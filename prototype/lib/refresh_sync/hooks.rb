module RefreshSync
  # All runtime instrumentation. Read-side hooks no-op unless a Recording is
  # active on the current thread; write-side hooks no-op unless some cohort
  # watches the written table.
  module Hooks
    # Read side: relations that execute while capturing.
    module RelationObserver
      def exec_queries(&block)
        records = super
        Recording.current&.record_relation(self)
        records
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

    def self.install!
      return if @installed
      @installed = true

      ActiveRecord::Relation.prepend(RelationObserver)
      ActiveRecord::Relation.prepend(BulkWriteObserver)
      ActiveRecord::Base.singleton_class.prepend(InstantiateObserver)
      ActiveRecord::Base.include(WriteObserver)

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
