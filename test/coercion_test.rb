require_relative "test_helper"

# Type coercion across the serialization boundary: a read set persisted as
# JSON and reloaded must still match live writes whose attribute values are
# native Ruby types — and must NOT match values that merely look similar.
class CoercionTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def roundtrip(read_set)
    Upkeep::ReadSet.from_h(JSON.parse(JSON.generate(read_set.to_h)))
  end

  def change(kind: :update, id: nil, attrs: {})
    Upkeep::Change.new(table: "cards", id: id, kind: kind,
                            new_attrs: attrs, old_attrs: attrs)
  end

  def test_string_vs_integer_ids_match_after_roundtrip
    rs = Upkeep::ReadSet.new
    rs.record_id("cards", "5")
    reloaded = roundtrip(rs)
    assert reloaded.matches?(change(id: 5)), "\"5\" and 5 are the same primary key"
    refute reloaded.matches?(change(id: 6)), "different ids must not match"
  end

  def test_date_predicates_survive_json_roundtrip
    rs = Upkeep::ReadSet.new
    rs.record_predicate("cards", { "due_on" => [Date.new(2026, 1, 1)] })
    reloaded = roundtrip(rs)

    assert reloaded.matches?(change(kind: :insert, attrs: { "due_on" => Date.new(2026, 1, 1) })),
      "persisted \"2026-01-01\" string must match a live Date write"
    refute reloaded.matches?(change(kind: :insert, attrs: { "due_on" => Date.new(2026, 1, 2) })),
      "coercion must not blur distinct dates into a false positive"
  end

  def test_uuid_string_predicates_roundtrip
    uuid = "0195c2ae-9f42-7aa3-b18e-000000000001"
    rs = Upkeep::ReadSet.new
    rs.record_predicate("cards", { "uid" => [uuid] })
    reloaded = roundtrip(rs)
    assert reloaded.matches?(change(kind: :insert, attrs: { "uid" => uuid }))
    refute reloaded.matches?(change(kind: :insert, attrs: { "uid" => uuid.sub("1", "2") }))
  end

  # End to end: capture through a real request, persist to the AR store,
  # "restart", then match a live write with native-typed attributes.
  def test_persisted_cohort_matches_live_typed_write
    due = Date.new(2026, 9, 1)
    Card.create!(board: @board1, title: "Due", status: "open", due_on: due)

    in_process(sim_process) do
      get "/boards/#{@board1.id}" # captures cards where board_id=<int>
      assert_response :success
    end
    stream = response.headers["X-Upkeep-Stream"]

    in_process(sim_process) do # restart: read set now comes from JSON
      Card.create!(board_id: @board1.id.to_s, title: "Typed", status: "open", due_on: due)
    end
    assert_refreshes(stream, 1)
  end

  # The false-positive direction end to end: a write to a DIFFERENT board
  # must not match the persisted-and-reloaded predicate.
  def test_persisted_cohort_does_not_over_match
    in_process(sim_process) do
      get "/boards/#{@board1.id}"
    end
    stream = response.headers["X-Upkeep-Stream"]

    in_process(sim_process) do
      Card.create!(board: @board2, title: "Elsewhere", status: "open")
    end
    assert_no_refresh(stream)
  end
end
