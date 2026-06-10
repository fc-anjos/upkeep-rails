# frozen_string_literal: true

require "test_helper"

class ClusterGuardTest < Minitest::Test
  def test_no_problems_when_not_clustered
    guard = build_guard(worker_count: 0, cable_adapter: "async", subscription_store: :memory)

    assert_empty guard.problems
    refute guard.error?
    refute guard.warning?
    assert_nil guard.message
  end

  def test_async_cable_adapter_with_workers_is_a_problem
    guard = build_guard(worker_count: 2, cable_adapter: "async", subscription_store: :active_record)

    assert guard.warning?
    refute guard.error?
    assert_includes guard.message, "solid_cable"
    assert_includes guard.message, "redis"
    assert_includes guard.message, "2 workers"
  end

  def test_memory_store_with_workers_is_a_problem
    guard = build_guard(worker_count: 2, cable_adapter: "solid_cable", subscription_store: :memory)

    assert guard.warning?
    assert_includes guard.message, "subscription_store = :active_record"
  end

  def test_cross_process_adapter_and_store_pass_clustered_check
    guard = build_guard(
      worker_count: 4,
      cable_adapter: "solid_cable",
      subscription_store: :active_record,
      environment: "production"
    )

    assert_empty guard.problems
    refute guard.error?
  end

  def test_problems_raise_severity_in_production
    guard = build_guard(
      worker_count: 2,
      cable_adapter: "async",
      subscription_store: :active_record,
      environment: "production"
    )

    assert guard.error?
    refute guard.warning?
  end

  def test_both_problems_are_reported_together
    guard = build_guard(worker_count: 2, cable_adapter: "async", subscription_store: :memory)

    assert_equal 2, guard.problems.size
  end

  def test_nil_inputs_do_not_crash_the_check
    guard = Upkeep::Rails::ClusterGuard.new(
      cable_adapter: nil,
      worker_count: nil,
      subscription_store: nil,
      environment: nil
    )

    assert_empty guard.problems
    refute guard.error?
  end

  def test_validate_cluster_safety_raises_in_production
    guard = build_guard(
      worker_count: 2,
      cable_adapter: "async",
      subscription_store: :active_record,
      environment: "production"
    )

    error = assert_raises(Upkeep::Rails::ConfigurationError) do
      Upkeep::Rails.send(:validate_cluster_safety!, environment: "production", guard: guard)
    end

    assert_includes error.message, "solid_cable"
    assert_includes error.message, "redis"
  end

  def test_validate_cluster_safety_warns_once_outside_production
    Upkeep::Rails.instance_variable_set(:@cluster_warning_logged, nil)
    guard = build_guard(worker_count: 2, cable_adapter: "async", subscription_store: :active_record)

    capture_io do
      assert Upkeep::Rails.send(:validate_cluster_safety!, environment: "development", guard: guard)
      assert Upkeep::Rails.send(:validate_cluster_safety!, environment: "development", guard: guard)
    end

    assert Upkeep::Rails.instance_variable_get(:@cluster_warning_logged)
  ensure
    Upkeep::Rails.instance_variable_set(:@cluster_warning_logged, nil)
  end

  private

  def build_guard(worker_count:, cable_adapter:, subscription_store:, environment: "development")
    Upkeep::Rails::ClusterGuard.new(
      cable_adapter: cable_adapter,
      worker_count: worker_count,
      subscription_store: subscription_store,
      environment: environment
    )
  end
end
