require "set"

module RefreshSync
  # What one rendered page read, per table:
  #   ids        - primary keys actually materialized (execution-time truth)
  #   predicates - array of {attr => [values]} conjunctions from simple where
  #                clauses; used to catch rows *entering* the set (inserts /
  #                updates moving a row into view)
  #   table_reasons - reasons this table degraded to table-level dependency
  #
  # Every record call optionally carries a provenance node address; the same
  # dependencies are then also indexed per node (pure metadata for page-level
  # matching — matches? ignores it; region routing reads it via
  # matching_node_addresses).
  #
  # Serializes to plain JSON (for the ActiveRecord store); all value
  # comparisons go through Coercion so a JSON-reloaded read set still
  # matches live writes (Date vs "2026-01-01", 5 vs "5", ...).
  class ReadSet
    Deps = Struct.new(:ids, :predicates, :table_reasons) do
      def self.empty = new(Set.new, [], [])
    end

    TableDeps = Struct.new(:ids, :predicates, :table_reasons, :node_reads) do
      def self.empty = new(Set.new, [], [], {})
    end

    def initialize
      @tables = {}
    end

    attr_reader :tables

    def deps(table) = @tables[table] ||= TableDeps.empty

    def node_deps(table, node)
      deps(table).node_reads[node] ||= Deps.empty
    end

    def record_id(table, id, node: nil)
      return if id.nil?
      deps(table).ids << id
      node_deps(table, node).ids << id if node
    end

    # An empty predicate is meaningful: it comes from an unscoped relation
    # (Card.all) and correctly matches every change to the table.
    def record_predicate(table, predicate, node: nil)
      deps(table).predicates << predicate
      node_deps(table, node).predicates << predicate if node
    end

    def record_table(table, reason, node: nil)
      deps(table).table_reasons << reason
      node_deps(table, node).table_reasons << reason if node
    end

    def matches?(change)
      table_deps = @tables[change.table]
      return false unless table_deps
      deps_match?(table_deps, change)
    end

    # Node addresses whose own recorded dependencies match this change —
    # the region-routing counterpart of matches?.
    def matching_node_addresses(change)
      table_deps = @tables[change.table]
      return [] unless table_deps
      table_deps.node_reads.select { |_addr, deps| deps_match?(deps, change) }.keys
    end

    # True when every node-attributed dependency matching this change is in
    # `covered` — i.e. region delivery fully explains the change for this
    # read set. False when the change also matches page-level dependencies
    # recorded outside any node (controller reads).
    def change_covered_by?(change, covered)
      table_deps = @tables[change.table]
      return false unless table_deps
      matched = matching_node_addresses(change)
      return false if matched.empty?
      return false unless (matched - covered).empty?
      controller_deps = controller_only_deps(table_deps)
      !deps_match?(controller_deps, change)
    end

    def to_h
      @tables.to_h do |table, d|
        [table, {
          "ids" => d.ids.to_a,
          "predicates" => d.predicates.map { |p| p.transform_keys(&:to_s) },
          "table_reasons" => d.table_reasons.map(&:to_s),
          "node_reads" => d.node_reads.to_h do |addr, nd|
            [addr, {
              "ids" => nd.ids.to_a,
              "predicates" => nd.predicates.map { |p| p.transform_keys(&:to_s) },
              "table_reasons" => nd.table_reasons.map(&:to_s)
            }]
          end
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
        d.fetch("node_reads", {}).each do |addr, nd|
          node = rs.node_deps(table, addr)
          node.ids.merge(nd.fetch("ids", []))
          nd.fetch("predicates", []).each { |p| node.predicates << p }
          nd.fetch("table_reasons", []).each { |r| node.table_reasons << r.to_sym }
        end
      end
      rs
    end

    private

    def deps_match?(deps, change)
      return true if deps.table_reasons.any?
      return true if change.kind == :table && (deps.ids.any? || deps.predicates.any?)
      if change.id && deps.ids.any? { |i| Coercion.same?(change.table, "id", i, change.id) }
        return true
      end
      deps.predicates.any? { |pred| predicate_hit?(pred, change) }
    end

    # The page-level dependencies minus everything that was recorded under
    # some node (ids/predicates recorded twice — once page-level, once
    # node-level — so subtracting the node-attributed ones leaves controller
    # reads).
    def controller_only_deps(table_deps)
      node_ids = table_deps.node_reads.values.flat_map { |d| d.ids.to_a }.to_set
      node_predicates = table_deps.node_reads.values.flat_map(&:predicates)
      node_reasons = table_deps.node_reads.values.flat_map(&:table_reasons)
      Deps.new(
        table_deps.ids - node_ids,
        subtract_multiset(table_deps.predicates, node_predicates),
        subtract_multiset(table_deps.table_reasons, node_reasons)
      )
    end

    def subtract_multiset(all, remove)
      remaining = all.dup
      remove.each do |item|
        index = remaining.index(item)
        remaining.delete_at(index) if index
      end
      remaining
    end

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
