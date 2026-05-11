# frozen_string_literal: true

module Upkeep
  module Benchmark
    module Runner
      class WorkloadExecutor
        attr_reader :config, :workload, :k6_runner, :metrics_collector, :cold_capacity_failures

        def initialize(config, workload, k6_runner:, metrics_collector:)
          @config = config
          @workload = workload
          @k6_runner = k6_runner
          @metrics_collector = metrics_collector
          @cold_capacity_failures = []
        end

        def run_named_workload
          case workload.key
          when "matrix/warm_steady_state_chat"
            run_matrix_warm_steady_state_chat_workload
          when "matrix/cold_connect_churn_chat"
            run_matrix_cold_connect_churn_chat_workload
          when "matrix/compare"
            run_matrix_warm_steady_state_chat_workload
            run_matrix_board_workload
            run_matrix_cold_connect_churn_chat_workload
          when "render_dedup/featured_item_compare"
            run_render_dedup_featured_item_compare_workload
          when "memory_ceiling/shared_feed_churn"
            run_memory_ceiling_shared_feed_churn_workload
          else
            raise WorkloadError, "unsupported non-route workload: #{workload.key}"
          end
          0
        end

        private
          # ── Matrix ──────────────────────────────────────────────

          def run_matrix_warm_steady_state_chat_workload
            with_bench_vus(workload.vus) do
              run_k6!("matrix/chat_upkeep.js", upkeep_url, relay_ws_url, "Matrix warm steady state chat - Upkeep")
              poll_upkeep("after-matrix-warm-steady-chat-upkeep")
              return if config.upkeep_only?

              run_k6!("matrix/chat_turbo.js", turbo_url, turbo_ws_url, "Matrix warm steady state chat - Turbo")
              poll_turbo("after-matrix-warm-steady-chat-turbo")
            end
          end

          def run_matrix_cold_connect_churn_chat_workload
            with_bench_vus(workload.vus) do
              cold_gate("upkeep") do
                k6_runner.run("matrix/chat_upkeep_cold_connect_churn.js", upkeep_url, relay_ws_url, "Matrix cold connect churn chat - Upkeep", capacity_gate: true)
              end
              poll_upkeep("after-matrix-cold-connect-churn-chat-upkeep")
              return if config.upkeep_only?

              cold_gate("turbo") do
                k6_runner.run("matrix/chat_turbo_cold_connect_churn.js", turbo_url, turbo_ws_url, "Matrix cold connect churn chat - Turbo", capacity_gate: true)
              end
              poll_turbo("after-matrix-cold-connect-churn-chat-turbo")
            end
          end

          def run_matrix_board_workload
            with_bench_vus(workload.vus) do
              run_k6!("matrix/board_upkeep.js", upkeep_url, relay_ws_url, "Matrix board - Upkeep")
              poll_upkeep("after-matrix-board-upkeep")
              return if config.upkeep_only?

              run_k6!("matrix/board_turbo.js", turbo_url, turbo_ws_url, "Matrix board - Turbo")
              poll_turbo("after-matrix-board-turbo")
            end
          end

          # ── Render dedup (k6-only) ──────────────────────────────

          def run_render_dedup_featured_item_compare_workload
            with_bench_vus(workload.vus) do
              run_k6!("render_dedup/mixed_region_feed_ivar.js", upkeep_url, relay_ws_url, "Render dedup featured item compare - Upkeep")
              poll_upkeep("after-render-dedup-featured-item-compare-upkeep")
              return if config.upkeep_only?

              run_k6!("render_dedup/mixed_region_feed_ivar_turbo.js", turbo_url, turbo_ws_url, "Render dedup featured item compare - Turbo")
              poll_turbo("after-render-dedup-featured-item-compare-turbo")
            end
          end

          # ── Memory ceiling ──────────────────────────────────────

          def run_memory_ceiling_shared_feed_churn_workload
            timeout_seconds = config.integer_env("K6_TIMEOUT_SECONDS", config.tier == "report" ? 3600 : 900)
            with_bench_vus(workload.vus) do
              run_k6!("memory_ceiling/shared_feed_churn_upkeep.js", upkeep_url, relay_ws_url, "Memory ceiling shared feed churn - Upkeep", timeout_seconds: timeout_seconds)
              poll_upkeep("after-memory-ceiling-shared-feed-churn-upkeep")
              return if config.upkeep_only?

              run_k6!("memory_ceiling/shared_feed_churn_turbo.js", turbo_url, turbo_ws_url, "Memory ceiling shared feed churn - Turbo", timeout_seconds: timeout_seconds)
              poll_turbo("after-memory-ceiling-shared-feed-churn-turbo")
            end
          end

          def cold_gate(role)
            status = yield
            if status == 99
              cold_capacity_failures << role
              status
            elsif status != 0
              raise WorkloadError, "k6 failed with status #{status}"
            else
              status
            end
          end

          def with_bench_vus(vus)
            previous = config.env["BENCH_VUS"]
            config.env["BENCH_VUS"] = vus.to_s if vus
            yield
          ensure
            previous.nil? ? config.env.delete("BENCH_VUS") : config.env["BENCH_VUS"] = previous
          end

          def run_k6!(...)
            status = k6_runner.run(...)
            raise WorkloadError, "k6 failed with status #{status}" unless status.zero?
          end

          def poll_upkeep(label) = metrics_collector.poll(config.upkeep_port, "upkeep", label)
          def poll_turbo(label) = metrics_collector.poll(config.turbo_port, "turbo", label)
          def upkeep_url = "http://localhost:#{config.upkeep_port}"
          def turbo_url = "http://localhost:#{config.turbo_port}"
          def relay_ws_url = "ws://localhost:#{config.relay_ws_port}"
          def turbo_ws_url = "ws://localhost:#{config.turbo_port}/cable"
      end
    end
  end
end
