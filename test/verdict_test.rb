require_relative "test_helper"

# The verdict layer: one committed write against one set of recorded
# dependencies -> :irrelevant | :in_place | :leave | :enter | :maybe.
# Verdicts only ever REMOVE work that is provably unnecessary; anything
# unprovable is :maybe, which dispatches exactly like the old conservative
# match. The composition rule (adopted from hanataba): the verdict of a
# tree is the most conservative verdict of any node.
class VerdictTest < ActiveSupport::TestCase
  V = Upkeep::Verdict

  def deps(ids: [], predicates: [], table_reasons: [], membership: [], aggregates: [])
    Upkeep::ReadSet::Deps.new(
      Set.new(ids), predicates, table_reasons, membership, aggregates
    )
  end

  def aggregate(fn:, column: nil, group: [], predicates: [{}])
    { "fn" => fn, "column" => column, "group" => group, "predicates" => predicates }
  end

  def update(id:, old_attrs:, new_attrs:, columns: nil)
    Upkeep::Fact.new(table: "cards", id: id, kind: :update,
                          old_attrs: old_attrs, new_attrs: new_attrs,
                          columns: columns || (new_attrs.keys - ["id"]))
  end

  OPEN = { "status" => ["open"] }.freeze

  # --- the four provable transitions, single-row facts ---------------------

  def test_update_moving_a_row_into_the_predicate_set_is_enter
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "done" },
                  new_attrs: { "id" => 9, "status" => "open" })
    assert_equal :enter, V.of(deps(predicates: [OPEN]), fact)
  end

  def test_update_moving_a_row_out_of_the_predicate_set_is_leave
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "open" },
                  new_attrs: { "id" => 9, "status" => "done" })
    assert_equal :leave, V.of(deps(predicates: [OPEN]), fact)
  end

  def test_update_inside_the_set_is_in_place
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "open", "title" => "a" },
                  new_attrs: { "id" => 9, "status" => "open", "title" => "b" })
    assert_equal :in_place, V.of(deps(predicates: [OPEN]), fact)
  end

  def test_update_outside_the_set_is_irrelevant
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "done", "title" => "a" },
                  new_attrs: { "id" => 9, "status" => "done", "title" => "b" })
    assert_equal :irrelevant, V.of(deps(predicates: [OPEN]), fact)
  end

  # --- inserts and deletes -------------------------------------------------

  def test_insert_into_the_set_is_enter_and_outside_is_irrelevant
    inside = Upkeep::Fact.new(table: "cards", id: 9, kind: :insert,
                                   new_attrs: { "id" => 9, "status" => "open" })
    outside = Upkeep::Fact.new(table: "cards", id: 9, kind: :insert,
                                    new_attrs: { "id" => 9, "status" => "done" })
    assert_equal :enter, V.of(deps(predicates: [OPEN]), inside)
    assert_equal :irrelevant, V.of(deps(predicates: [OPEN]), outside)
  end

  def test_delete_of_a_member_is_leave_for_ids_and_predicates
    fact = Upkeep::Fact.new(table: "cards", id: 9, kind: :delete,
                                 old_attrs: { "id" => 9, "status" => "open" })
    assert_equal :leave, V.of(deps(ids: [9]), fact)
    assert_equal :leave, V.of(deps(predicates: [OPEN]), fact)
    assert_equal :irrelevant, V.of(deps(ids: [7]), fact)
  end

  # --- id-membership (loaded rows) -----------------------------------------

  def test_update_of_a_loaded_id_is_in_place_and_of_another_id_irrelevant
    fact = update(id: 9, old_attrs: { "id" => 9, "title" => "a" },
                  new_attrs: { "id" => 9, "title" => "b" })
    assert_equal :in_place, V.of(deps(ids: [9]), fact)
    assert_equal :irrelevant, V.of(deps(ids: [7]), fact)
  end

  # --- bulk facts: honest unknown-before, never a raise, never a vanish ----

  def test_bulk_update_overlapping_loaded_ids_is_in_place
    fact = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :update,
                                 ids: [3, 9])
    assert_equal :in_place, V.of(deps(ids: [9]), fact)
  end

  def test_bulk_delete_overlapping_loaded_ids_is_leave
    fact = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :delete,
                                 ids: [9])
    assert_equal :leave, V.of(deps(ids: [9]), fact)
  end

  def test_bulk_with_unknown_op_stays_conservative_on_id_overlap
    fact = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, ids: [9])
    assert_equal :maybe, V.of(deps(ids: [9]), fact)
  end

  def test_bulk_update_without_attrs_is_maybe_for_a_non_pk_predicate
    fact = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :update,
                                 ids: [3], columns: ["status"])
    assert_equal :maybe, V.of(deps(predicates: [OPEN]), fact)
  end

  def test_bulk_pure_pk_predicate_is_answered_exactly_by_the_known_ids
    hit = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :update,
                                ids: [5], columns: ["title"])
    miss = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :update,
                                 ids: [6], columns: ["title"])
    pk_pred = { "id" => [5] }
    assert_equal :in_place, V.of(deps(predicates: [pk_pred]), hit)
    assert_equal :irrelevant, V.of(deps(predicates: [pk_pred]), miss)
  end

  def test_bulk_delete_pure_pk_predicate_is_leave_or_irrelevant
    hit = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :delete, ids: [5])
    miss = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :delete, ids: [6])
    pk_pred = { "id" => [5] }
    assert_equal :leave, V.of(deps(predicates: [pk_pred]), hit)
    assert_equal :irrelevant, V.of(deps(predicates: [pk_pred]), miss)
  end

  # --- bulk facts with projected after-values (RETURNING columns) ----------

  def test_bulk_after_values_outside_the_set_with_disjoint_set_columns_is_irrelevant
    # SET title: the write provably could not change `status`, and the row's
    # after-state says status != open -> before == after == out. Pure savings.
    fact = Upkeep::Fact.new(
      table: "cards", kind: :bulk_rows, op: :update, ids: [9],
      columns: ["title"], rows: { 9 => { "status" => "done" } }
    )
    assert_equal :irrelevant, V.of(deps(predicates: [OPEN]), fact)
  end

  def test_bulk_after_values_inside_the_set_with_disjoint_set_columns_is_in_place
    fact = Upkeep::Fact.new(
      table: "cards", kind: :bulk_rows, op: :update, ids: [9],
      columns: ["title"], rows: { 9 => { "status" => "open" } }
    )
    assert_equal :in_place, V.of(deps(predicates: [OPEN]), fact)
  end

  def test_bulk_after_values_outside_the_set_with_touching_set_columns_is_maybe
    # SET status: the row is out now but may have been in before -> cannot
    # prove :leave away, cannot prove :irrelevant. Conservative.
    fact = Upkeep::Fact.new(
      table: "cards", kind: :bulk_rows, op: :update, ids: [9],
      columns: ["status"], rows: { 9 => { "status" => "done" } }
    )
    assert_equal :maybe, V.of(deps(predicates: [OPEN]), fact)
  end

  def test_bulk_insert_rows_never_before_satisfy_a_predicate
    inside = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :insert,
                                   ids: [9], rows: { 9 => { "status" => "open" } })
    outside = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :insert,
                                    ids: [9], rows: { 9 => { "status" => "done" } })
    assert_equal :enter, V.of(deps(predicates: [OPEN]), inside)
    assert_equal :irrelevant, V.of(deps(predicates: [OPEN]), outside)
  end

  def test_bulk_upsert_cannot_prove_before_state
    fact = Upkeep::Fact.new(table: "cards", kind: :bulk_rows, op: :upsert,
                                 ids: [9], rows: { 9 => { "status" => "done" } })
    # after = out, before unknowable (may have been open) -> conservative.
    assert_equal :maybe, V.of(deps(predicates: [OPEN]), fact)
  end

  # --- table-level facts and table-level deps ------------------------------

  def test_table_level_fact_is_maybe_when_any_dependency_exists
    fact = Upkeep::Fact.new(table: "cards", kind: :table)
    assert_equal :maybe, V.of(deps(ids: [1]), fact)
    assert_equal :maybe, V.of(deps(predicates: [OPEN]), fact)
    assert_equal :irrelevant, V.of(deps, fact)
  end

  def test_table_level_dependency_is_always_maybe
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "done" },
                  new_attrs: { "id" => 9, "status" => "done" })
    assert_equal :maybe, V.of(deps(table_reasons: [:joined_table]), fact)
  end

  # --- membership-only predicates (count / exists pages) -------------------

  def test_membership_only_predicate_downgrades_in_place_to_irrelevant
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "open", "title" => "a" },
                  new_attrs: { "id" => 9, "status" => "open", "title" => "b" })
    assert_equal :irrelevant, V.of(deps(membership: [OPEN]), fact)
  end

  def test_membership_only_predicate_keeps_structural_verdicts
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "done" },
                  new_attrs: { "id" => 9, "status" => "open" })
    assert_equal :enter, V.of(deps(membership: [OPEN]), fact)
  end

  # --- value-sensitive aggregates (capacity-dashboard shapes) --------------
  # sum(duration) by user_id over status=open: membership changes always
  # refresh; an in-place write refreshes only when it touches the
  # aggregated column, a grouping key, or a predicate column.

  SUM = { "fn" => "sum", "column" => "duration", "group" => ["user_id"],
          "predicates" => [{ "status" => ["open"] }] }.freeze

  def in_place_fact(columns:, extra: {})
    base = { "id" => 9, "status" => "open", "user_id" => 1, "duration" => 5,
             "title" => "a" }
    update(id: 9, old_attrs: base,
           new_attrs: base.merge(extra.presence || columns.to_h { |c| [c, "changed"] }),
           columns: columns)
  end

  def test_aggregate_in_place_write_to_an_unrelated_column_is_irrelevant
    fact = in_place_fact(columns: ["title"])
    assert_equal :irrelevant, V.of(deps(aggregates: [SUM]), fact)
    # The old membership-shaped behavior — the asserted delta: the same
    # write against the same predicate recorded plainly still refreshes.
    assert_equal :in_place, V.of(deps(predicates: [{ "status" => ["open"] }]), fact)
  end

  def test_aggregate_in_place_write_to_the_aggregated_column_refreshes
    fact = in_place_fact(columns: ["duration"], extra: { "duration" => 7 })
    assert_equal :in_place, V.of(deps(aggregates: [SUM]), fact)
  end

  def test_aggregate_in_place_write_to_a_grouping_key_refreshes
    fact = in_place_fact(columns: ["user_id"], extra: { "user_id" => 2 })
    assert_equal :in_place, V.of(deps(aggregates: [SUM]), fact)
  end

  def test_aggregate_membership_changes_always_refresh
    enter = update(id: 9, old_attrs: { "id" => 9, "status" => "done" },
                   new_attrs: { "id" => 9, "status" => "open" })
    leave = update(id: 9, old_attrs: { "id" => 9, "status" => "open" },
                   new_attrs: { "id" => 9, "status" => "done" })
    assert_equal :enter, V.of(deps(aggregates: [SUM]), enter)
    assert_equal :leave, V.of(deps(aggregates: [SUM]), leave)
  end

  def test_aggregate_write_outside_the_predicate_stays_irrelevant
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "done", "title" => "a" },
                  new_attrs: { "id" => 9, "status" => "done", "title" => "b" })
    assert_equal :irrelevant, V.of(deps(aggregates: [SUM]), fact)
  end

  def test_aggregate_with_unknown_changed_columns_refreshes_conservatively
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "open", "title" => "a" },
                  new_attrs: { "id" => 9, "status" => "open", "title" => "b" },
                  columns: nil)
    fact.columns = nil
    assert_equal :in_place, V.of(deps(aggregates: [SUM]), fact)
  end

  def test_aggregate_with_unknown_predicate_columns_refreshes_conservatively
    opaque = aggregate(fn: "sum", column: "duration",
                       predicates: [{ "__fragment__" => {
                         "op" => "opaque", "columns" => [], "evaluable" => false
                       } }])
    fact = in_place_fact(columns: ["title"])
    assert_equal :maybe, V.of(deps(aggregates: [opaque]), fact)
  end

  def test_whole_row_count_in_place_never_refreshes
    count = aggregate(fn: "count", predicates: [{ "status" => ["open"] }])
    fact = in_place_fact(columns: ["status"], extra: { "status" => "open" })
    assert_equal :irrelevant, V.of(deps(aggregates: [count]), fact),
      "membership unchanged = count unchanged, whatever columns moved"
  end

  def test_grouped_count_refreshes_on_a_grouping_key_move
    count = aggregate(fn: "count", group: ["user_id"],
                      predicates: [{ "status" => ["open"] }])
    moved = in_place_fact(columns: ["user_id"], extra: { "user_id" => 2 })
    titled = in_place_fact(columns: ["title"])
    assert_equal :in_place, V.of(deps(aggregates: [count]), moved)
    assert_equal :irrelevant, V.of(deps(aggregates: [count]), titled)
  end

  def test_maximum_in_place_change_to_the_aggregated_column_refreshes
    max = aggregate(fn: "maximum", column: "duration",
                    predicates: [{ "status" => ["open"] }])
    fact = in_place_fact(columns: ["duration"], extra: { "duration" => 1 })
    assert_equal :in_place, V.of(deps(aggregates: [max]), fact),
      "the old max may not survive a downward move — always refresh"
  end

  def test_unscoped_aggregate_treats_every_row_as_a_member
    unscoped = aggregate(fn: "sum", column: "duration")
    title_edit = in_place_fact(columns: ["title"])
    duration_edit = in_place_fact(columns: ["duration"], extra: { "duration" => 7 })
    insert = Upkeep::Fact.new(table: "cards", id: 9, kind: :insert,
                              new_attrs: { "id" => 9, "duration" => 3 })
    assert_equal :irrelevant, V.of(deps(aggregates: [unscoped]), title_edit)
    assert_equal :in_place, V.of(deps(aggregates: [unscoped]), duration_edit)
    assert_equal :enter, V.of(deps(aggregates: [unscoped]), insert)
  end

  def test_aggregates_survive_serialization
    rs = Upkeep::ReadSet.new
    rs.record_aggregate("cards", SUM.dup)
    reloaded = Upkeep::ReadSet.from_h(JSON.parse(JSON.generate(rs.to_h)))
    title_edit = in_place_fact(columns: ["title"])
    duration_edit = in_place_fact(columns: ["duration"], extra: { "duration" => 7 })
    refute reloaded.matches?(title_edit),
      "the value-sensitive skip must survive the store round trip"
    assert reloaded.matches?(duration_edit)
    assert_equal [SUM], reloaded.tables.fetch("cards").aggregates
  end

  def test_aggregates_survive_fragment_slice_absorb
    rs = Upkeep::ReadSet.new
    rs.record_aggregate("cards", SUM.dup, node: "n1")
    absorbed = Upkeep::ReadSet.new
    absorbed.absorb(JSON.parse(JSON.generate(rs.to_h)))
    assert_equal [SUM], absorbed.tables.fetch("cards").aggregates
    assert_equal [SUM], absorbed.tables.fetch("cards").node_reads.fetch("n1").aggregates
  end

  # --- composition ---------------------------------------------------------

  def test_the_tree_verdict_is_the_most_conservative_of_any_node
    assert_equal :maybe, V.combine(:irrelevant, :maybe)
    assert_equal :enter, V.combine(:in_place, :enter)
    assert_equal :leave, V.combine(:irrelevant, :leave)
    assert_equal :in_place, V.combine(:in_place, :irrelevant)
    # Across a whole Deps: an in_place id-hit plus an entering predicate
    # composes to the structural verdict.
    fact = update(id: 9, old_attrs: { "id" => 9, "status" => "done" },
                  new_attrs: { "id" => 9, "status" => "open" })
    assert_equal :enter, V.of(deps(ids: [9], predicates: [OPEN]), fact)
  end

  def test_relevance_and_structure_predicates
    assert V.relevant?(:maybe)
    assert V.relevant?(:in_place)
    refute V.relevant?(:irrelevant)
    assert V.structural?(:enter)
    assert V.structural?(:leave)
    assert V.structural?(:maybe)
    refute V.structural?(:in_place)
  end

  # --- ReadSet integration -------------------------------------------------

  def test_read_set_page_verdict_and_matches_agree
    rs = Upkeep::ReadSet.new
    rs.record_predicate("cards", OPEN.dup)
    inside = update(id: 9, old_attrs: { "id" => 9, "status" => "open", "title" => "a" },
                    new_attrs: { "id" => 9, "status" => "open", "title" => "b" })
    outside = update(id: 9, old_attrs: { "id" => 9, "status" => "done", "title" => "a" },
                     new_attrs: { "id" => 9, "status" => "done", "title" => "b" })
    assert_equal :in_place, rs.verdict(inside)
    assert rs.matches?(inside)
    assert_equal :irrelevant, rs.verdict(outside)
    refute rs.matches?(outside)
    assert_equal :irrelevant, rs.verdict(update(id: 1, old_attrs: {}, new_attrs: {}).tap { |f| f.table = "boards" })
  end

  def test_membership_predicates_survive_serialization
    rs = Upkeep::ReadSet.new
    rs.record_predicate("cards", OPEN.dup, membership_only: true)
    reloaded = Upkeep::ReadSet.from_h(rs.to_h)
    in_place = update(id: 9, old_attrs: { "id" => 9, "status" => "open", "title" => "a" },
                      new_attrs: { "id" => 9, "status" => "open", "title" => "b" })
    flip = update(id: 9, old_attrs: { "id" => 9, "status" => "done" },
                  new_attrs: { "id" => 9, "status" => "open" })
    refute reloaded.matches?(in_place), "membership-only skip must survive the store round trip"
    assert reloaded.matches?(flip)
  end
end
