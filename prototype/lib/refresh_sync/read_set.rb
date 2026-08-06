require "set"

module RefreshSync
  # What one rendered page read, per table:
  #   ids        - primary keys actually materialized (execution-time truth)
  #   predicates - array of {attr => [values]} conjunctions from simple where
  #                clauses; used to catch rows *entering* the set (inserts /
  #                updates moving a row into view)
  #   table_reasons - reasons this table degraded to table-level dependency
  class ReadSet
    TableDeps = Struct.new(:ids, :predicates, :table_reasons) do
      def self.empty = new(Set.new, [], [])
    end

    def initialize
      @tables = {}
    end

    attr_reader :tables

    def deps(table) = @tables[table] ||= TableDeps.empty

    def record_id(table, id)
      deps(table).ids << id unless id.nil?
    end

    # An empty predicate is meaningful: it comes from an unscoped relation
    # (Card.all) and correctly matches every change to the table.
    def record_predicate(table, predicate)
      deps(table).predicates << predicate
    end

    def record_table(table, reason)
      deps(table).table_reasons << reason
    end

    def matches?(change)
      table_deps = @tables[change.table]
      return false unless table_deps
      return true if table_deps.table_reasons.any?
      return true if change.kind == :table # bulk write, unknown rows: fail open
      return true if change.id && table_deps.ids.include?(change.id)

      table_deps.predicates.any? { |pred| predicate_hit?(pred, change) }
    end

    private

    # A predicate hits when the row satisfies it after the write (it entered
    # or lives in the set) or satisfied it before (it left the set).
    def predicate_hit?(predicate, change)
      [change.new_attrs, change.old_attrs].compact.any? do |attrs|
        predicate.all? do |attr, values|
          attrs.key?(attr) && values.include?(attrs[attr])
        end
      end
    end
  end
end
