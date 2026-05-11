# frozen_string_literal: true

require "test_helper"
require "pathname"
require_relative "../../benchmark/runner/config"

class BenchmarkLayoutTest < Minitest::Test
  def test_runner_defaults_to_in_repo_benchmark_apps
    config = Upkeep::Benchmark::Runner::Config.new(
      env: {
        "BENCH_FAMILY" => "matrix",
        "BENCH_WORKLOAD" => "pipeline_smoke",
        "BENCH_TIER" => "smoke"
      },
      bench_dir: benchmark_root.to_s,
      timestamp: "test"
    )

    assert_equal "upkeep-app", File.basename(config.upkeep_app_dir)
    assert_equal "turbo-app", File.basename(config.turbo_app_dir)
    assert_path_exists config.upkeep_app_dir
    assert_path_exists config.turbo_app_dir
  end

  def test_benchmark_tree_excludes_generated_runtime_artifacts
    generated_artifacts = Dir[
      benchmark_root.join("results/**/*").to_s,
      benchmark_root.join("**/*.sqlite3*").to_s,
      benchmark_root.join("**/*.log").to_s,
      benchmark_root.join("**/node_modules/**/*").to_s,
      benchmark_root.join("**/playwright-report/**/*").to_s,
      benchmark_root.join("**/test-results/**/*").to_s,
      benchmark_root.join("**/config/master.key").to_s,
      benchmark_root.join("**/config/credentials.yml.enc").to_s
    ]

    assert_empty generated_artifacts
  end

  private

  def benchmark_root
    Pathname(__dir__).join("../../benchmark").expand_path
  end
end
