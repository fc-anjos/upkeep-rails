require_relative "test_helper"

# The census hot cluster, proven end to end: a capacity dashboard rendering
# TimeLog.where(status: "billable").group(:user_id).sum(:duration). The
# verdict layer knows the sum's value can only change through membership,
# the aggregated column, or a grouping key — so a title edit on a member
# row costs the page nothing, while every write the sum could see still
# refreshes.
class AggregateSavingsTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def setup
    super
    TimeLog.delete_all
    @log1 = TimeLog.create!(user_id: 1, title: "Sprint work", status: "billable",
                            duration: 120, logged_on: Date.new(2026, 8, 3))
    @log2 = TimeLog.create!(user_id: 2, title: "Review", status: "billable",
                            duration: 60, logged_on: Date.new(2026, 8, 4))
    @internal = TimeLog.create!(user_id: 1, title: "Standup", status: "internal",
                                duration: 15, logged_on: Date.new(2026, 8, 3))
  end

  def stream_for(path)
    get path
    assert_response :success
    response.headers["X-Upkeep-Stream"].tap { |s| assert s, "capture should register a cohort" }
  end

  def test_the_dashboard_records_a_value_sensitive_aggregate_descriptor
    stream_for("/census/capacity")
    deps = Upkeep::Capture.last_recording.read_set.tables.fetch("time_logs")
    assert_equal [{ "fn" => "sum", "column" => "duration", "group" => ["user_id"],
                    "predicates" => [{ "status" => ["billable"] }] }],
                 deps.aggregates
    assert_empty deps.table_reasons, "the aggregate must not degrade the table"
    assert_empty deps.predicates,
      "the descriptor subsumes the membership predicate — no coarse duplicate may ride along"
  end

  # The headline saving: a title/status-adjacent edit on a MEMBER row is
  # observed, evaluated, and PROVEN unable to move any group's sum.
  def test_title_edit_on_a_member_row_costs_nothing
    stream = stream_for("/census/capacity")
    analyzed_before = Upkeep.stats[:writes_analyzed]
    @log1.update!(title: "Sprint work (renamed)")
    assert_no_refresh(stream)
    assert_operator Upkeep.stats[:writes_analyzed], :>, analyzed_before,
      "the write must have been observed and then PROVEN irrelevant, not missed"
  end

  def test_duration_edit_on_a_member_row_refreshes
    stream = stream_for("/census/capacity")
    @log1.update!(duration: 150)
    assert_refreshes(stream, 1)
  end

  def test_grouping_key_move_refreshes
    stream = stream_for("/census/capacity")
    @log1.update!(user_id: 2)
    assert_refreshes(stream, 1)
  end

  def test_row_entering_the_window_refreshes
    stream = stream_for("/census/capacity")
    @internal.update!(status: "billable")
    assert_refreshes(stream, 1)
  end

  def test_row_leaving_the_window_refreshes
    stream = stream_for("/census/capacity")
    @log2.update!(status: "internal")
    assert_refreshes(stream, 1)
  end

  def test_row_outside_the_window_costs_nothing
    stream = stream_for("/census/capacity")
    @internal.update!(duration: 30, title: "Longer standup")
    assert_no_refresh(stream)
  end

  # Raw-SET bulk write: the parsed SET-column list composes with the
  # aggregate's sensitive-column check — title moves nothing the sum sees.
  def test_raw_set_update_all_on_an_unrelated_column_costs_nothing
    stream = stream_for("/census/capacity")
    analyzed_before = Upkeep.stats[:writes_analyzed]
    TimeLog.where(status: "billable").update_all("title = 'Renamed in bulk'")
    assert_no_refresh(stream)
    assert_operator Upkeep.stats[:writes_analyzed], :>, analyzed_before

    # The same bulk shape against the aggregated column still refreshes.
    TimeLog.where(status: "billable").update_all("duration = duration + 1")
    assert_refreshes(stream, 1)
  end

  # Durable path: the same skip/refresh decisions hold when the cohort is
  # matched from the ActiveRecord store (a different process re-reading
  # the persisted read set), not the in-memory one that captured it.
  def test_value_sensitivity_survives_the_durable_store
    in_process(sim_process) do
      stream = stream_for("/census/capacity")
      @log1.update!(title: "Renamed across processes")
      assert_no_refresh(stream)
      @log1.update!(duration: 121)
      assert_refreshes(stream, 1)
    end
  end
end
