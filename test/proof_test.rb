require_relative "test_helper"

class ProofTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  # (a) precision: board-1 page refreshes on board-1 writes, not board-2 writes
  def test_scoped_page_refreshes_only_for_relevant_writes
    stream = visit_board(@board1)

    Card.create!(board: @board2, title: "Elsewhere", status: "open")
    assert_no_refresh(stream)

    @card1.update!(title: "Renamed")
    assert_refreshes(stream, 1)
  end

  # (b) membership: an insert matching the captured where-predicate refreshes
  def test_insert_matching_predicate_triggers_refresh
    stream = visit_board(@board1)

    Card.create!(board: @board1, title: "Second", status: "open")
    assert_refreshes(stream, 1)
  end

  def test_insert_not_matching_predicate_does_not_refresh
    stream = visit_board(@board1)

    Card.create!(board: @board1, title: "Done card", status: "done")
    assert_no_refresh(stream)
  end

  # (b2) unscoped relation: any insert refreshes
  def test_unscoped_relation_catches_any_insert
    get "/cards"
    assert_response :success
    stream = response.headers["X-RefreshSync-Stream"]

    Card.create!(board: @board2, title: "Anywhere")
    assert_refreshes(stream, 1)
  end

  # (c) coalescing: N rapid writes -> one refresh
  def test_rapid_writes_coalesce_into_one_refresh
    stream = visit_board(@board1)

    5.times { |i| @card1.update!(title: "Rename #{i}") }
    assert_refreshes(stream, 1)
  end

  # (d) bulk + raw SQL degrade to table-level fallback
  def test_update_all_triggers_table_level_refresh
    stream = visit_board(@board1)

    Card.where(board_id: @board2.id).update_all(status: "archived")
    assert_refreshes(stream, 1)
  end

  def test_raw_sql_write_triggers_table_level_refresh
    stream = visit_board(@board1)

    ActiveRecord::Base.connection.execute(
      "UPDATE cards SET title = 'raw' WHERE board_id = #{@board2.id}"
    )
    assert_refreshes(stream, 1)
  end

  # (e) zero cohorts: writes do no matching work and nothing broadcasts
  def test_no_cohorts_means_no_write_side_work
    assert_equal 0, RefreshSync.stats[:writes_analyzed]

    @card1.update!(title: "Quiet")
    Card.create!(board: @board1, title: "Still quiet")
    Card.where(board_id: @board1.id).update_all(status: "x")
    sleep 0.5

    assert_equal 0, RefreshSync.stats[:writes_analyzed],
      "no cohorts registered: write path must not analyze anything"
    assert_equal 0, RefreshSync.stats[:refreshes_broadcast]
  end

  # multiple viewers: same write fans out to both cohorts, separately debounced
  def test_two_viewers_each_get_one_refresh
    stream_a = visit_board(@board1)
    stream_b = visit_board(@board1)
    refute_equal stream_a, stream_b

    @card1.update!(title: "Fan out")
    assert_refreshes(stream_a, 1)
    assert_equal 1, broadcasts(stream_b).size
  end

  # capture must not tax uncaptured requests or non-GETs
  def test_read_analysis_only_runs_while_capturing
    baseline = RefreshSync.stats[:relations_analyzed]
    Card.where(board_id: @board1.id).to_a
    assert_equal baseline, RefreshSync.stats[:relations_analyzed]

    visit_board(@board1)
    assert_operator RefreshSync.stats[:relations_analyzed], :>, baseline
  end
end
