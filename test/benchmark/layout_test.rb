# frozen_string_literal: true

require "test_helper"
require "pathname"
require_relative "../../benchmark/runner/config"
require_relative "../../benchmark/runner/k6_runner"
require_relative "../../benchmark/runner/metrics_collector"

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

  def test_k6_runner_writes_comparison_report_summary_names
    runner = Upkeep::Benchmark::Runner::K6Runner.new(matrix_config)

    assert_equal "matrix-chat-warm-upkeep.json", runner.send(:summary_file_for, "matrix/chat_upkeep.js", "matrix-chat_upkeep")
    assert_equal "matrix-chat-warm-turbo.json", runner.send(:summary_file_for, "matrix/chat_turbo.js", "matrix-chat_turbo")
    assert_equal "matrix-chat-cold-upkeep.json", runner.send(:summary_file_for, "matrix/chat_upkeep_cold_connect_churn.js", "matrix-chat_upkeep_cold_connect_churn")
    assert_equal "matrix-board-upkeep.json", runner.send(:summary_file_for, "matrix/board_upkeep.js", "matrix-board_upkeep")
  end

  def test_matrix_metrics_poll_uses_lightweight_upkeep_endpoint
    collector = Upkeep::Benchmark::Runner::MetricsCollector.new(matrix_config)

    assert_equal "/bench/metrics", collector.send(:metrics_path_for, "upkeep", "before")
    assert_equal "/bench/metrics", collector.send(:metrics_path_for, "upkeep", "final")
  end

  def test_gemspec_packages_public_runtime_and_installer
    files = Gem::Specification.load(project_root.join("upkeep-rails.gemspec").to_s).files

    assert_includes files, "lib/upkeep.rb"
    assert_includes files, "lib/upkeep/rails/testing.rb"
    assert_includes files, "lib/generators/upkeep/install/install_generator.rb"
    assert_includes files, "lib/generators/upkeep/install/templates/subscription.js"
    refute_includes files, "lib/upkeep/proof_support.rb"
    refute_includes files, "lib/upkeep/proofs/end_to_end.rb"
    refute_includes files, "lib/upkeep/probes/herb_surface.rb"
    refute_includes files, "lib/upkeep/domain.rb"
  end

  def test_memory_ceiling_metrics_poll_can_request_memory_snapshots
    collector = Upkeep::Benchmark::Runner::MetricsCollector.new(memory_ceiling_config)

    assert_equal "/bench/metrics?memory_phase=before", collector.send(:metrics_path_for, "upkeep", "before")
    assert_equal "/bench/metrics?memory_phase=final", collector.send(:metrics_path_for, "upkeep", "final")
  end

  private

  def matrix_config
    config_for(
      "BENCH_FAMILY" => "matrix",
      "BENCH_WORKLOAD" => "compare",
      "BENCH_TIER" => "gate"
    )
  end

  def memory_ceiling_config
    config_for(
      "BENCH_FAMILY" => "memory_ceiling",
      "BENCH_WORKLOAD" => "shared_feed_churn",
      "BENCH_TIER" => "smoke"
    )
  end

  def config_for(env)
    Upkeep::Benchmark::Runner::Config.new(
      env: env,
      bench_dir: benchmark_root.to_s,
      timestamp: "test"
    )
  end

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
