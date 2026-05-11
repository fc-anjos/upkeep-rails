# frozen_string_literal: true

require "fileutils"

require_relative "types"

module Upkeep
  module Benchmark
    module Runner
      class Config
        attr_reader :env, :bench_dir, :results_dir, :timestamp
        attr_reader :family, :workload_name, :tier
        attr_reader :upkeep_port, :turbo_port, :relay_metrics_port, :relay_ws_port, :k6_api_port
        attr_reader :puma_workers, :puma_threads, :rss_sample_interval, :smoke_progress_file
        attr_reader :upkeep_app_dir, :turbo_app_dir, :upkeep_database, :turbo_database
        attr_reader :relay_metrics_url, :upkeep_broker_socket
        attr_reader :bench_secret_key_base
        attr_accessor :iterations_per_vu, :num_users

        def initialize(env:, bench_dir:, timestamp:)
          @env = env
          @bench_dir = bench_dir
          @results_dir = File.join(bench_dir, "results")
          @timestamp = timestamp

          initialize_scalar_config
          initialize_socket_config
          initialize_app_config
        end

        def upkeep_only? = @upkeep_only == "1"

        def integer_env(key, default) = Integer(env.fetch(key, default))

        def port_with_offset(base) = base + @port_offset

        def checksum(value) = value.bytes.sum.to_s

        def listen_backlog
          @listen_backlog ||= Integer(`sysctl -n kern.ipc.somaxconn 2>/dev/null || sysctl -n net.core.somaxconn 2>/dev/null || echo 128`)
        end

        private
          def initialize_scalar_config
            @port_offset = integer_env("BENCH_PORT_OFFSET", 0)
            raise WorkloadError, "BENCH_PORT_OFFSET must be a non-negative integer (got #{@port_offset})" if @port_offset.negative?

            @family = env.fetch("BENCH_FAMILY", "matrix")
            @workload_name = env.fetch("BENCH_WORKLOAD", "compare")
            @tier = env.fetch("BENCH_TIER", "gate")
            @upkeep_only = env.fetch("BENCH_UPKEEP_ONLY", "0")
            raise WorkloadError, "BENCH_UPKEEP_ONLY must be 0 or 1 (got #{@upkeep_only})" unless %w[0 1].include?(@upkeep_only)

            @upkeep_port = integer_env("UPKEEP_PORT", port_with_offset(3000))
            @turbo_port = integer_env("TURBO_PORT", port_with_offset(3001))
            @relay_metrics_port = integer_env("RELAY_METRICS_PORT", port_with_offset(9394))
            @relay_ws_port = integer_env("RELAY_WS_PORT", port_with_offset(9393))
            @k6_api_port = integer_env("K6_API_PORT", port_with_offset(6565))
            @iterations_per_vu = integer_env("K6_ITERATIONS", default_iterations_per_vu)
            env.delete("K6_ITERATIONS")
            # Single-worker default: the upkeep dispatch reactor lives
            # in-process and holds subscription state in a per-process
            # Memory store. Multi-worker requires a broker fan-out role
            # that is a follow-up plan; until then a fair upkeep/turbo
            # comparison runs both with one worker.
            @puma_workers = integer_env("PUMA_WORKERS", 1)
            @puma_threads = integer_env("PUMA_THREADS", 5)
            @num_users = integer_env("NUM_USERS", 200)
            @rss_sample_interval = integer_env("RSS_SAMPLE_INTERVAL", 5)
            @smoke_progress_file = env["SMOKE_PROGRESS_FILE"]
            @bench_secret_key_base = env.fetch("BENCH_SECRET_KEY_BASE", "benchmark-key-base-not-for-production-use-only")
          end

          def default_iterations_per_vu
            tier == "smoke" ? 5 : 20
          end

          def initialize_socket_config
            socket_namespace = env.fetch("BENCH_SOCKET_NAMESPACE") { checksum(bench_dir) }
            socket_namespace = socket_namespace.gsub(/[^A-Za-z0-9_-]/, "")[0, 24]
            socket_namespace = "bench" if socket_namespace.empty?
            socket_token = env.fetch("BENCH_SOCKET_TOKEN", "#{timestamp}_#{$$}")

            @upkeep_broker_socket = env.fetch("UPKEEP_BROKER_SOCKET", "/tmp/sr_#{socket_namespace}_#{socket_token}_broker.sock")
            env["UPKEEP_BROKER_SOCKET_PATH"] = upkeep_broker_socket
            @relay_metrics_url = "http://127.0.0.1:#{relay_metrics_port}/metrics"
          end

          def initialize_app_config
            upkeep_basename, turbo_basename = app_basenames_for_family
            @upkeep_app_dir = env.fetch("UPKEEP_APP_DIR", File.join(bench_dir, upkeep_basename))
            @turbo_app_dir = env.fetch("TURBO_APP_DIR", File.join(bench_dir, turbo_basename))

            upkeep_db_env, turbo_db_env = database_env_keys_for_family
            @upkeep_database = env.fetch(upkeep_db_env, File.join(upkeep_app_dir, "storage", "benchmark-upkeep-#{timestamp}.sqlite3"))
            @turbo_database = env.fetch(turbo_db_env, File.join(turbo_app_dir, "storage", "benchmark-turbo-#{timestamp}.sqlite3"))
            env[upkeep_db_env] = upkeep_database
            env[turbo_db_env] = turbo_database

            env["UPKEEP_CABLE_CHANNEL_PREFIX"] ||= "upkeep_bench_#{checksum(bench_dir)}"
            env["TURBO_CABLE_CHANNEL_PREFIX"] ||= "turbo_bench_#{checksum(bench_dir)}"
            FileUtils.mkdir_p(File.dirname(upkeep_database))
            FileUtils.mkdir_p(File.dirname(turbo_database))
          end

          # Each family targets a specific app pair and DB env key pair.
          # Enumerate explicitly so an unknown family raises at boot
          # instead of silently defaulting to the synthetic-app pair.
          FAMILY_APP_PAIR = {
            "matrix" => %w[upkeep-app turbo-app],
            "render_dedup" => %w[upkeep-app turbo-app],
            "classifier" => %w[upkeep-app turbo-app],
            "render_parallelism" => %w[upkeep-app turbo-app],
            "memory_ceiling" => %w[upkeep-app turbo-app]
          }.freeze

          FAMILY_DATABASE_ENV_KEYS = {
            "matrix" => %w[UPKEEP_BENCH_DATABASE TURBO_BENCH_DATABASE],
            "render_dedup" => %w[UPKEEP_BENCH_DATABASE TURBO_BENCH_DATABASE],
            "classifier" => %w[UPKEEP_BENCH_DATABASE TURBO_BENCH_DATABASE],
            "render_parallelism" => %w[UPKEEP_BENCH_DATABASE TURBO_BENCH_DATABASE],
            "memory_ceiling" => %w[UPKEEP_BENCH_DATABASE TURBO_BENCH_DATABASE]
          }.freeze

          def app_basenames_for_family
            FAMILY_APP_PAIR.fetch(family) do
              raise WorkloadError, "unknown benchmark family: #{family.inspect} (known: #{FAMILY_APP_PAIR.keys.inspect})"
            end
          end

          def database_env_keys_for_family
            FAMILY_DATABASE_ENV_KEYS.fetch(family) do
              raise WorkloadError, "unknown benchmark family: #{family.inspect} (known: #{FAMILY_DATABASE_ENV_KEYS.keys.inspect})"
            end
          end
      end
    end
  end
end
