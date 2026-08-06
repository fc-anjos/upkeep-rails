require_relative "test_helper"

# The verdict layer's measurable savings, end to end. Each scenario used to
# cost a conservative refresh; each is now PROVEN unnecessary and costs
# nothing — while the neighboring relevant write still refreshes, so the
# proof cuts waste, never coverage.
class VerdictSavingsTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def stream_for(path)
    get path
    assert_response :success
    response.headers["X-RefreshSync-Stream"]
  end

  # Bulk write to rows provably outside the page's predicate: the RETURNING
  # projection carries the rows' after-values, the SET columns are disjoint
  # from the predicate's attrs (title cannot move status or board_id), so
  # before == after == out -> :irrelevant -> no refresh at all. The old
  # conservative path refreshed every such page.
  def test_bulk_write_outside_the_predicate_is_proven_irrelevant
    done = Card.create!(board: @board2, title: "Done elsewhere", status: "done")
    stream = stream_for("/boards/#{@board1.id}") # cards where board_id=1, status=open

    analyzed_before = RefreshSync.stats[:writes_analyzed]
    Card.where(status: "done").update_all(title: "Renamed in bulk")
    assert_no_refresh(stream)
    assert_operator RefreshSync.stats[:writes_analyzed], :>, analyzed_before,
      "the write must have been observed and then PROVEN irrelevant, not missed"

    # The same bulk write shape against rows INSIDE the predicate still
    # refreshes — savings never cost coverage.
    Card.where(id: @card1.id).update_all(title: "Renamed in view")
    assert_refreshes(stream, 1)
    done.destroy!
  end

  # A row that enters the page's dependency set and leaves it again inside
  # one debounce window nets to nothing: the page never showed it, and the
  # refresh would repaint an identical page.
  def test_enter_then_leave_inside_one_window_nets_to_no_refresh
    stream = stream_for("/boards/#{@board1.id}")

    churn = Card.create!(board: @board1, title: "Flash", status: "open") # :enter
    churn.update!(status: "done")                                        # :leave
    assert_no_refresh(stream)
    assert_equal 1, RefreshSync.stats[:refreshes_netted],
      "the netted refresh must be counted, not silently absent"

    # A lone :enter still refreshes.
    Card.create!(board: @board1, title: "Real", status: "open")
    assert_refreshes(stream, 1)
  end
end
