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
    generated_artifacts = tracked_benchmark_files.grep(
      %r{
        \Abenchmark/(results/|.+/
          (Gemfile\.lock|log/.+|tmp/.+|storage/.+\.sqlite3.*|node_modules/.+|playwright-report/.+|test-results/.+|config/(master\.key|credentials\.yml\.enc))
        )\z
      }x
    )

    assert_empty generated_artifacts
  end

  private

  def tracked_benchmark_files
    Dir.chdir(project_root) { `git ls-files benchmark`.split("\n") }
  end

  def benchmark_root
    project_root.join("benchmark")
  end

  def project_root
    Pathname(__dir__).join("../..").expand_path
  end
end
