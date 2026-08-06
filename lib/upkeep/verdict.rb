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
      verdict
    end

    # A dependency that exists at all, hit by a write we know nothing
    # about, is conservatively relevant; an empty Deps matches nothing.
    def conservative(deps)
      empty = deps.ids.empty? && deps.predicates.empty? &&
              deps.membership_predicates.empty? && deps.table_reasons.empty?
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
    # is true; otherwise unknown.
    def satisfied?(pred, table, attrs)
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
      (pred.keys.map(&:to_s) & written_columns.map(&:to_s)).empty?
    end
  end
end
