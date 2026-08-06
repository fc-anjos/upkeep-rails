require "set"

module RefreshSync
  # What one rendered page read, per table:
  #   ids        - primary keys actually materialized (execution-time truth)
  #   predicates - array of {attr => [values]} conjunctions from simple where
  #                clauses; used to catch rows *entering* the set (inserts /
  #                updates moving a row into view)
  #   table_reasons - reasons this table degraded to table-level dependency
  #
  # Serializes to plain JSON (for the ActiveRecord store); all value
  # comparisons go through Coercion so a JSON-reloaded read set still
  # matches live writes (Date vs "2026-01-01", 5 vs "5", ...).
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
      if change.id && table_deps.ids.any? { |i| Coercion.same?(change.table, "id", i, change.id) }
        return true
      end

      table_deps.predicates.any? { |pred| predicate_hit?(pred, change) }
    end

    def to_h
      @tables.to_h do |table, d|
        [table, {
          "ids" => d.ids.to_a,
          "predicates" => d.predicates.map { |p| p.transform_keys(&:to_s) },
          "table_reasons" => d.table_reasons.map(&:to_s)
        }]
      end
    end

    def self.from_h(h)
      rs = new
      h.each do |table, d|
        deps = rs.deps(table)
        deps.ids.merge(d.fetch("ids", []))
        d.fetch("predicates", []).each { |p| deps.predicates << p }
        d.fetch("table_reasons", []).each { |r| deps.table_reasons << r.to_sym }
      end
      rs
    end

    private

    # A predicate hits when the row satisfies it after the write (it entered
    # or lives in the set) or satisfied it before (it left the set).
    def predicate_hit?(predicate, change)
      [change.new_attrs, change.old_attrs].compact.any? do |attrs|
        predicate.all? do |attr, values|
          attrs.key?(attr.to_s) &&
            values.any? { |v| Coercion.same?(change.table, attr, v, attrs[attr.to_s]) }
        end
      end
    end
  end
end
