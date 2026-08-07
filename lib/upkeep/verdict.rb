module Upkeep
  # The verdict of one committed write against one set of recorded
  # dependencies: what happened to each written row's membership in the
  # dependency set.
  #
  #   :irrelevant  provably out -> out          no work at all
  #   :in_place    in -> in, content moved      membership unchanged
  #   :leave       in -> out                    structural
  #   :enter       out -> in                    structural
  #   :maybe       not provable either way      conservative
  #
  # Composition rule (hanataba's formulation, adopted): the verdict of a
  # tree is the MOST CONSERVATIVE verdict of any node. Verdicts only ever
  # remove work that is provably unnecessary — anything unprovable is
  # :maybe, which dispatches exactly like the old conservative match, so
  # freshness fails open by construction.
  module Verdict
    ORDER = { irrelevant: 0, in_place: 1, leave: 2, enter: 3, maybe: 4 }.freeze

    module_function

    def relevant?(verdict) = verdict != :irrelevant

    # Membership changed (or might have): counts, ordering and pagination
    # can move, so narrow in-place delivery cannot be sufficient.
    def structural?(verdict) = ORDER.fetch(verdict) >= ORDER[:leave]

    def combine(a, b) = ORDER.fetch(a) >= ORDER.fetch(b) ? a : b

    # The verdict of `fact` against one Deps: ids (loaded-row identity),
    # predicates (membership + content), membership-only predicates
    # (count/exists pages, where in-place content moves are invisible),
    # table-level reasons (always conservative).
    def of(deps, fact)
      return conservative(deps) if deps.table_reasons.any? || fact.kind == :table
      verdict = ids_verdict(deps, fact)
      deps.predicates.each do |pred|
        verdict = combine(verdict, predicate_verdict(pred, fact))
      end
      deps.membership_predicates.each do |pred|
        verdict = combine(verdict, membership_verdict(pred, fact))
      end
      Array(deps.aggregates).each do |agg|
        verdict = combine(verdict, aggregate_verdict(agg, fact))
      end
      verdict
    end

    # A dependency that exists at all, hit by a write we know nothing
    # about, is conservatively relevant; an empty Deps matches nothing.
    def conservative(deps)
      empty = deps.ids.empty? && deps.predicates.empty? &&
              deps.membership_predicates.empty? &&
              Array(deps.aggregates).empty? && deps.table_reasons.empty?
      empty ? :irrelevant : :maybe
    end

    # Membership by identity: a loaded row's id never changes, so an update
    # keeps it a member (:in_place) and a delete removes it (:leave). New
    # ids can never be in a past render's loaded set.
    def ids_verdict(deps, fact)
      return :irrelevant if deps.ids.empty?
      return :maybe if fact.row_ids.empty? # a row of unknown identity
      hit = fact.row_ids.any? do |rid|
        deps.ids.any? { |i| Coercion.same?(fact.table, "id", i, rid) }
      end
      return :irrelevant unless hit
      case fact.operation
      when :update, :upsert then :in_place
      when :delete then :leave
      when :insert then :in_place # an insert landing on a loaded id: upsert-shaped
      else :maybe
      end
    end

    # A count/exists page sees membership only: an in-place content move is
    # invisible to it.
    def membership_verdict(pred, fact)
      verdict = predicate_verdict(pred, fact)
      verdict == :in_place ? :irrelevant : verdict
    end

    # A value-sensitive aggregate dependency ({"fn", "column", "group",
    # "predicates"}): membership changes (:enter/:leave/:maybe) always
    # refresh — any aggregate over the set may change. :in_place refreshes
    # only when the write touched a column the aggregate's VALUE can see:
    # the aggregated column, a grouping column, or a predicate column.
    # Whole-row count sees no content at all — with membership unchanged
    # only a grouping-key move can change it.
    def aggregate_verdict(agg, fact)
      # A descriptor without predicates never comes off the recording path
      # (unscoped records the match-all {}); treat it as membership unknown.
      return :maybe if agg["predicates"].empty?
      verdict = agg["predicates"].reduce(:irrelevant) do |acc, pred|
        combine(acc, predicate_verdict(pred, fact))
      end
      verdict == :in_place ? aggregate_in_place_verdict(agg, fact) : verdict
    end

    # Membership provably unchanged: compare the write's changed columns
    # against the aggregate's value-sensitive columns. Every unknown
    # resolves to refresh (freshness fails open); a provably disjoint
    # write is the pure saving.
    def aggregate_in_place_verdict(agg, fact)
      sensitive = aggregate_sensitive_columns(agg)
      return :irrelevant if sensitive && sensitive.empty?
      return :in_place if sensitive.nil? || fact.columns.nil?
      (sensitive & fact.columns.map(&:to_s)).any? ? :in_place : :irrelevant
    end

    # The columns an aggregate's value depends on beyond membership: the
    # grouping keys, plus — for value aggregates — the aggregated column
    # and the predicate columns. Whole-row count (nil column) is blind to
    # row content: only its grouping keys matter. nil = unknown (a
    # predicate whose columns the parser cannot name) — never disjoint.
    def aggregate_sensitive_columns(agg)
      group = Array(agg["group"]).map(&:to_s)
      return group unless agg["column"]
      pred_columns = agg["predicates"].map { |pred| predicate_columns(pred) }
      return nil if pred_columns.any?(&:nil?)
      group + [agg["column"].to_s] + pred_columns.flatten
    end

    # Most conservative row verdict across every row the fact touched.
    def predicate_verdict(pred, fact)
      fact.each_row.reduce(:irrelevant) do |acc, row|
        combine(acc, transition(side(pred, fact, row, :before), side(pred, fact, row, :after)))
      end
    end

    def transition(before, after)
      return :maybe if before.nil? || after.nil?
      if before then after ? :in_place : :leave
      else after ? :enter : :irrelevant
      end
    end

    # Was the predicate satisfied on this side? true / false / nil(unknown).
    # :absent (row does not exist on that side) is definite false.
    def side(pred, fact, row, which)
      attrs = row[which]
      return false if attrs == :absent
      return unknown_side(pred, fact, row, which) if attrs == :unknown
      known = row[:id].nil? ? attrs : attrs.merge("id" => row[:id])
      answer = satisfied?(pred, fact.table, known)
      return answer unless answer.nil?
      # Partial attrs (a RETURNING projection) may not cover the predicate;
      # a definite answer stands, an unknown may still borrow across a
      # provably disjoint write.
      borrow_across_disjoint_write(pred, fact, row, which)
    end

    # Unknown attrs still answer pure-pk predicates through the row's own
    # id (identity never changes), else may borrow across a disjoint write.
    def unknown_side(pred, fact, row, which)
      if pred.keys == ["id"]
        return row[:id].nil? ? nil : satisfied?(pred, fact.table, { "id" => row[:id] })
      end
      borrow_across_disjoint_write(pred, fact, row, which)
    end

    # An unknown BEFORE borrows the after answer when the write's SET
    # columns are provably disjoint from the predicate's attrs (the write
    # could not have changed the predicate's value).
    def borrow_across_disjoint_write(pred, fact, row, which)
      return nil unless which == :before && columns_disjoint?(pred, fact.columns)
      side(pred, fact, row, :after)
    end

    # Conjunction over the predicate's attrs with partial knowledge: any
    # conjunct known false makes the whole predicate false; all known true
    # is true; otherwise unknown. Parsed SQL fragments (stored under the
    # "__fragment__" key) evaluate through SqlPredicate's three-valued
    # logic — UNKNOWN flows through the same nil as a missing attr.
    def satisfied?(pred, table, attrs)
      if SqlPredicate.fragment?(pred)
        return SqlPredicate.evaluate(SqlPredicate.unwrap(pred), table, attrs)
      end
      unknown = false
      pred.each do |attr, values|
        key = attr.to_s
        unless attrs.key?(key)
          unknown = true
          next
        end
        hit = values.any? { |v| Coercion.same?(table, key, v, attrs[key]) }
        return false unless hit
      end
      unknown ? nil : true
    end

    def columns_disjoint?(pred, written_columns)
      return false unless written_columns # nil = assume all columns written
      columns = predicate_columns(pred)
      return false unless columns # predicate columns unknown: never disjoint
      (columns & written_columns.map(&:to_s)).empty?
    end

    # The columns a predicate depends on: hash predicates read their keys;
    # parsed fragments carry an explicit column list. An empty fragment
    # column list means "columns unknown" — nil, never provably disjoint.
    def predicate_columns(pred)
      return pred.keys.map(&:to_s) unless SqlPredicate.fragment?(pred)
      SqlPredicate.unwrap(pred)["columns"].presence&.map(&:to_s)
    end
  end
end
