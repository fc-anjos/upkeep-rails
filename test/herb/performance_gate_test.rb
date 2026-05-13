# frozen_string_literal: true

require "test_helper"

class HerbPerformanceGateTest < Minitest::Test
  def test_records_performance_metrics_and_passes_budgets
    report = Upkeep::HerbSupport::PerformanceGate.new.run
    metrics = report.fetch(:metrics)

    assert report.fetch(:gate_passed), report.fetch(:failures).inspect
    assert_empty report.fetch(:failures)
    assert_operator metrics.fetch(:capture_duration_ms), :>=, 0.0
    assert_operator metrics.fetch(:capture_allocations), :>, 0
    assert_operator metrics.fetch(:replay_duration_ms), :>=, 0.0
    assert_operator metrics.fetch(:replay_sql_count), :>=, 0
    assert_operator metrics.fetch(:graph_nodes), :>, 0
    assert_operator metrics.fetch(:graph_edges), :>, 0
    assert_operator metrics.fetch(:payload_bytes), :>, 0
    assert_operator metrics.fetch(:manifest_direct_replay_targets), :>=, 1
    assert metrics.fetch(:replay_matches_full_target)
  end
end
