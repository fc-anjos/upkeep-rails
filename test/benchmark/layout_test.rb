# frozen_string_literal: true

require "test_helper"
require "pathname"
require_relative "../../benchmark/runner/config"
require_relative "../../benchmark/runner/k6_runner"
require_relative "../../benchmark/runner/metrics_collector"
require_relative "../../benchmark/runner/workload_registry"
require_relative "../../benchmark/shared/bench_metrics"

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

  def test_identity_free_feed_compare_is_a_turbo_comparison_workload
    workload = Upkeep::Benchmark::Runner::WorkloadRegistry.new(identity_free_feed_compare_config).resolve

    assert_equal "render_dedup/identity_free_feed_compare", workload.key
    assert workload.needs_turbo
    assert_nil workload.route_script
  end

  def test_benchmark_apps_emit_cable_connect_timing
    %w[upkeep-app turbo-app].each do |app_name|
      connection = benchmark_root.join(app_name, "app/channels/application_cable/connection.rb").read

      assert_includes connection, "BenchMetrics.instrument_cable_connect(self)"
    end
  end

  def test_matrix_metrics_poll_uses_lightweight_upkeep_endpoint
    collector = Upkeep::Benchmark::Runner::MetricsCollector.new(matrix_config)

    assert_equal "/bench/metrics", collector.send(:metrics_path_for, "upkeep", "before")
    assert_equal "/bench/metrics", collector.send(:metrics_path_for, "upkeep", "final")
  end

  def test_gemspec_packages_public_runtime_and_installer
    files = Gem::Specification.load(project_root.join("upkeep-rails.gemspec").to_s).files

    assert_includes files, "lib/upkeep-rails.rb"
    assert_includes files, "lib/upkeep.rb"
    assert_includes files, "lib/upkeep/rails/testing.rb"
    assert_includes files, "lib/upkeep/herb/developer_report.rb"
    assert_includes files, "lib/upkeep/herb/manifest_cache.rb"
    assert_includes files, "lib/upkeep/herb/manifest_diff.rb"
    assert_includes files, "lib/upkeep/herb/source_instrumenter.rb"
    assert_includes files, "lib/upkeep/herb/template_manifest.rb"
    assert_includes files, "lib/generators/upkeep/install/install_generator.rb"
    assert_includes files, "lib/generators/upkeep/install/templates/subscription.js"
    refute_includes files, "lib/upkeep/proof_support.rb"
    refute_includes files, "lib/upkeep/proofs/end_to_end.rb"
    refute_includes files, "lib/upkeep/probes/herb_surface.rb"
    refute_includes files, "lib/upkeep/herb/fallback_analyzer.rb"
    refute_includes files, "lib/upkeep/herb/performance_gate.rb"
    refute_includes files, "lib/upkeep/herb/runtime_alignment.rb"
    refute_includes files, "lib/upkeep/domain.rb"
  end

  def test_memory_ceiling_metrics_poll_can_request_memory_snapshots
    collector = Upkeep::Benchmark::Runner::MetricsCollector.new(memory_ceiling_config)

    assert_equal "/bench/metrics?memory_phase=before", collector.send(:metrics_path_for, "upkeep", "before")
    assert_equal "/bench/metrics?memory_phase=final", collector.send(:metrics_path_for, "upkeep", "final")
  end

  def test_benchmark_metrics_summarize_subscription_graphs_without_replay_values
    store = Upkeep::Rails.subscriptions
    store.reset
    BenchMetrics.reset_counters

    store.register(
      subscriber_id: "subscriber-a",
      recorder: reactivity_recorder,
      metadata: { "shared_stream_names" => ["upkeep:shared:test"] }
    )

    snapshot = BenchMetrics.snapshot
    graph = snapshot.fetch(:upkeep_reactivity).fetch(:subscription_graphs)
    ambient = graph.fetch(:ambient_replay_inputs)

    assert_equal 1, snapshot.fetch(:subscription_count)
    assert_equal 1, graph.fetch(:subscriptions)
    assert_equal 1, graph.fetch(:frames)
    assert_equal 4, graph.fetch(:dependencies)
    assert_equal 1, graph.fetch(:replay_recipes)
    assert_operator graph.fetch(:replay_recipe_bytes_total), :>, 0
    assert_equal 3, ambient.fetch(:total)
    assert_equal({ "cookie" => 1, "request" => 1, "session" => 1 }, ambient.fetch(:by_source))
    assert_equal 1, graph.fetch(:shared_stream_names)

    snapshot_json = JSON.generate(snapshot)
    refute_includes snapshot_json, "secret-session-value"
    refute_includes snapshot_json, "secret-cookie-value"
  ensure
    store&.reset
  end

  def test_benchmark_metrics_summarize_refused_boundaries_and_live_deopts
    BenchMetrics.reset_counters

    BenchMetrics.send(:increment_reactivity_tally, :refused_boundaries_by_reason, "opaque_active_record_relation")
    BenchMetrics.send(:increment_reactivity_tally, :live_deoptimizations_by_reason, "collection_member_replace_unproven")

    reactivity = BenchMetrics.snapshot.fetch(:upkeep_reactivity)

    assert_equal 1, reactivity.fetch(:refused_boundaries).fetch(:total)
    assert_equal({ "opaque_active_record_relation" => 1 }, reactivity.fetch(:refused_boundaries).fetch(:by_reason))
    assert_equal 1, reactivity.fetch(:delivery).fetch(:live_deoptimizations).fetch(:total)
    assert_equal(
      { "collection_member_replace_unproven" => 1 },
      reactivity.fetch(:delivery).fetch(:live_deoptimizations).fetch(:by_reason)
    )
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

  def identity_free_feed_compare_config
    config_for(
      "BENCH_FAMILY" => "render_dedup",
      "BENCH_WORKLOAD" => "identity_free_feed_compare",
      "BENCH_TIER" => "gate"
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

  def reactivity_recorder
    recorder = Upkeep::Runtime::Recorder.new
    recipe = Upkeep::Replay::Recipe.new(
      kind: "page",
      frame_id: "page:benchmark/test",
      target_kind: "page",
      target_id: "page:benchmark/test",
      runtime: "rails",
      replay: Upkeep::Replay::ControllerPage.new(
        controller_class: nil,
        action: "index",
        env: {
          "rack.session" => {
            "__upkeep_replay_type" => "rack_session",
            "values" => {
              "account_token" => "secret-session-value",
              "session_id" => "session-id"
            }
          },
          "HTTP_COOKIE" => "theme=secret-cookie-value"
        }
      )
    )

    recorder.graph.add_node(
      "page:benchmark/test",
      kind: :frame,
      payload: { kind: "page", recipe: recipe }
    )
    recorder.graph.add_edge(Upkeep::Runtime::Recorder::REQUEST_NODE_ID, "page:benchmark/test", reason: :contains)
    recorder.record_dependency(Upkeep::Dependencies::SessionValue.new(key: :account_token, value: "secret-session-value"))
    recorder.record_dependency(Upkeep::Dependencies::CookieValue.new(key: :theme, value: "secret-cookie-value"))
    recorder.record_dependency(Upkeep::Dependencies::RequestValue.new(key: :user_agent, value: "Benchmark"))
    recorder.record_dependency(
      Upkeep::Dependencies::ActiveRecordAttribute.new(
        table: "benchmark_cards",
        model: "BenchmarkCard",
        id: 1,
        attribute: "title"
      )
    )
    recorder
  end
end
