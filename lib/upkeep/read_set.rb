require "set"

module Upkeep
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
    # Every predicate recorded anywhere in a Deps, aggregate-carried ones
    # included — for consumers that reason about predicate shape (temporal
    # expiry, RETURNING projection candidates), not membership.
    module PredicateEnumeration
      def all_predicates
        predicates + membership_predicates +
          Array(aggregates).flat_map { |agg| agg["predicates"] }
      end
    end

    # membership_predicates: predicates recorded from doors that see only
    # set membership (count/exists) — an in-place content move is invisible
    # to them, so their :in_place verdict downgrades to :irrelevant.
    # aggregates: value-sensitive calculation descriptors —
    # {"fn", "column", "group", "predicates"} — whose :in_place verdict
    # depends on WHICH columns the write touched (see Verdict).
    Deps = Struct.new(:ids, :predicates, :table_reasons, :membership_predicates,
                      :aggregates) do
      include PredicateEnumeration
      def self.empty = new(Set.new, [], [], [], [])
    end

    TableDeps = Struct.new(:ids, :predicates, :table_reasons, :node_reads,
                           :columns, :membership_predicates, :aggregates) do
      include PredicateEnumeration
      def self.empty = new(Set.new, [], [], {}, Set.new, [], [])
    end

    # One human-readable label for an aggregate descriptor (dev summary,
    # upkeep:report): sum(duration) by user_id.
    def self.aggregate_label(agg)
      label = "#{agg["fn"]}(#{agg["column"] || "*"})"
      group = Array(agg["group"])
      group.any? ? "#{label} by #{group.join(", ")}" : label
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
      slices.each { |s| s.record_id(table, id, node: node) }
    end

    # An empty predicate is meaningful: it comes from an unscoped relation
    # (Card.all) and correctly matches every change to the table.
    # membership_only marks predicates from doors that see set membership
    # but never row content (count/exists).
    def record_predicate(table, predicate, node: nil, membership_only: false)
      predicate_list(deps(table), membership_only) << predicate
      predicate_list(node_deps(table, node), membership_only) << predicate if node
      slices.each do |s|
        s.record_predicate(table, predicate, node: node, membership_only: membership_only)
      end
    end

    # A value-sensitive aggregate dependency: the aggregate function, the
    # aggregated column (nil for whole-row count), the grouping columns and
    # the membership predicates of the aggregated set, as one descriptor.
    def record_aggregate(table, aggregate, node: nil)
      deps(table).aggregates << aggregate
      node_deps(table, node).aggregates << aggregate if node
      slices.each { |s| s.record_aggregate(table, aggregate, node: node) }
    end

    def record_table(table, reason, node: nil)
      deps(table).table_reasons << reason
      node_deps(table, node).table_reasons << reason if node
      slices.each { |s| s.record_table(table, reason, node: node) }
    end

    # Column-read evidence (attribute reads, pluck/calculate column lists).
    # Consumed ONLY to refine per-member divergence toward correct ejection:
    # presence of a column here means "this render read it"; absence proves
    # nothing (a column can be read through paths we don't see), so matching
    # never uses it to SKIP — fail open to row-level behavior.
    def record_column(table, column)
      deps(table).columns << column.to_s
      slices.each { |s| s.record_column(table, column) }
    end

    # The columns this read set is known to have read from `table`; nil when
    # no column evidence exists (callers must then assume all columns).
    def columns(table)
      cols = @tables[table]&.columns
      cols&.any? ? cols : nil
    end

    # --- fragment-cache slice capture ---------------------------------------
    # A slice is a nested ReadSet collecting everything recorded while it is
    # open (all open slices receive every record, so russian-doll outer
    # fragments cover their inner blocks' reads).

    def begin_slice
      slices << ReadSet.new
    end

    def end_slice
      slices.pop
    end

    # Replays a serialized read-set hash (a stored fragment slice) into this
    # read set through the record_* calls, so node metadata and any open
    # slices receive it too. Page-level entries that merely mirror node
    # entries are not double-absorbed.
    def absorb(h)
      h.each { |table, d| absorb_table(table, d) }
    end

    def matches?(change) = Verdict.relevant?(verdict(change))

    # The page-level verdict of a fact against this read set: what happened
    # to the page's dependency membership. :irrelevant means no work at all.
    def verdict(change)
      table_deps = @tables[change.table]
      return :irrelevant unless table_deps
      Verdict.of(table_deps, change)
    end

    # Node addresses whose own recorded dependencies match this change —
    # the region-routing counterpart of matches?.
    def matching_node_addresses(change)
      table_deps = @tables[change.table]
      return [] unless table_deps
      table_deps.node_reads.select { |_addr, deps| deps_match?(deps, change) }.keys
    end

    # True when every node-attributed dependency matching this change lies
    # inside one of the `regions` (address match or descendant) — i.e.
    # region delivery fully explains the change for this read set. False
    # when the change also matches page-level dependencies recorded outside
    # any node (controller reads).
    def change_covered_by?(change, regions)
      table_deps = @tables[change.table]
      return false unless table_deps
      matched = matching_node_addresses(change)
      return false if matched.empty?
      inside = matched.all? do |address|
        regions.any? { |region| address == region || address.start_with?("#{region}.") }
      end
      return false unless inside
      controller_deps = controller_only_deps(table_deps)
      !deps_match?(controller_deps, change)
    end

    def to_h
      @tables.to_h do |table, d|
        [table, serialize_deps(d).merge(
          "columns" => d.columns.to_a,
          "node_reads" => d.node_reads.transform_values { |nd| serialize_deps(nd) }
        )]
      end
    end

    def self.from_h(h)
      rs = new
      h.each do |table, d|
        load_deps(rs.deps(table), d)
        rs.deps(table).columns.merge(d.fetch("columns", []))
        d.fetch("node_reads", {}).each do |addr, nd|
          load_deps(rs.node_deps(table, addr), nd)
        end
      end
      rs
    end

    def self.load_deps(deps, h)
      deps.ids.merge(h.fetch("ids", []))
      h.fetch("predicates", []).each { |p| deps.predicates << p }
      h.fetch("membership_predicates", []).each { |p| deps.membership_predicates << p }
      h.fetch("aggregates", []).each { |a| deps.aggregates << a }
      h.fetch("table_reasons", []).each { |r| deps.table_reasons << r.to_sym }
    end

    private

    def slices
      @slices ||= []
    end

    def predicate_list(deps, membership_only)
      membership_only ? deps.membership_predicates : deps.predicates
    end

    def deps_match?(deps, change) = Verdict.relevant?(Verdict.of(deps, change))

    def serialize_deps(d)
      {
        "ids" => d.ids.to_a,
        "predicates" => d.predicates.map { |p| p.transform_keys(&:to_s) },
        "membership_predicates" => d.membership_predicates.map { |p| p.transform_keys(&:to_s) },
        "aggregates" => d.aggregates.map { |a| serialize_aggregate(a) },
        "table_reasons" => d.table_reasons.map(&:to_s)
      }
    end

    def serialize_aggregate(agg)
      agg.merge("predicates" => agg["predicates"].map { |p| p.transform_keys(&:to_s) })
    end

    def absorb_table(table, d)
      absorbed = Deps.empty
      d.fetch("node_reads", {}).each { |address, nd| absorb_node(table, address, nd, absorbed) }
      d.fetch("columns", []).each { |c| record_column(table, c) }
      (d.fetch("ids", []) - absorbed.ids.to_a).each { |id| record_id(table, id) }
      subtract_multiset(d.fetch("predicates", []), absorbed.predicates)
        .each { |p| record_predicate(table, p) }
      subtract_multiset(d.fetch("membership_predicates", []), absorbed.membership_predicates)
        .each { |p| record_predicate(table, p, membership_only: true) }
      subtract_multiset(d.fetch("aggregates", []), absorbed.aggregates)
        .each { |a| record_aggregate(table, a) }
      subtract_multiset(d.fetch("table_reasons", []).map(&:to_sym), absorbed.table_reasons)
        .each { |r| record_table(table, r) }
    end

    # Node-attributed dependencies replay through the record_* calls (so
    # open slices receive them too); `absorbed` collects what was recorded
    # so the page-level remainder is not double-absorbed.
    def absorb_node(table, address, nd, absorbed)
      nd.fetch("ids", []).each { |id| record_id(table, id, node: address); absorbed.ids << id }
      nd.fetch("predicates", []).each { |p| record_predicate(table, p, node: address); absorbed.predicates << p }
      nd.fetch("membership_predicates", []).each do |p|
        record_predicate(table, p, node: address, membership_only: true)
        absorbed.membership_predicates << p
      end
      nd.fetch("aggregates", []).each do |a|
        record_aggregate(table, a, node: address)
        absorbed.aggregates << a
      end
      nd.fetch("table_reasons", []).each { |r| record_table(table, r.to_sym, node: address); absorbed.table_reasons << r.to_sym }
    end

    # The page-level dependencies minus everything that was recorded under
    # some node (ids/predicates recorded twice — once page-level, once
    # node-level — so subtracting the node-attributed ones leaves controller
    # reads).
    def controller_only_deps(table_deps)
      node = table_deps.node_reads.values
      Deps.new(
        table_deps.ids - node.flat_map { |d| d.ids.to_a }.to_set,
        subtract_multiset(table_deps.predicates, node.flat_map(&:predicates)),
        subtract_multiset(table_deps.table_reasons, node.flat_map(&:table_reasons)),
        subtract_multiset(table_deps.membership_predicates, node.flat_map(&:membership_predicates)),
        subtract_multiset(table_deps.aggregates, node.flat_map(&:aggregates))
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
  end
end
