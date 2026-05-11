# frozen_string_literal: true

require "fileutils"
require "open3"

module Upkeep
  module Benchmark
    module Runner
      class K6Runner
        attr_reader :config

        def initialize(config)
          @config = config
        end

        def run(script, base_url, ws_url, scenario_name, capacity_gate: false, timeout_seconds: nil)
          log_stem = script.delete_suffix(".js").tr("/", "-")
          summary_file = summary_file_for(script, log_stem)
          timeout_seconds ||= config.integer_env("K6_TIMEOUT_SECONDS", config.tier == "smoke" ? 120 : 240)

          puts "\n== Running #{scenario_name} =="
          FileUtils.rm_f(File.join(config.results_dir, summary_file))

          status = run_logged(
            [ "timeout", "#{timeout_seconds}s", "k6", "run", "--address", "127.0.0.1:#{config.k6_api_port}", "k6/#{script}" ],
            log: File.join(config.results_dir, "#{log_stem}-#{config.timestamp}.log"),
            chdir: config.bench_dir,
            env: k6_env(base_url, ws_url, summary_file),
            unset: [ "K6_ITERATIONS" ]
          )

          return timeout_failure(timeout_seconds, scenario_name) if status == 124
          return capacity_failure(scenario_name) if status == 99 && capacity_gate
          return status unless status.zero?

          puts "✓ #{scenario_name} complete"
          0
        end

        private
          def summary_file_for(_script, log_stem)
            "#{log_stem.tr("_", "-")}.json"
          end

          def k6_env(base_url, ws_url, summary_file)
            {
              "BASE_URL" => base_url,
              "WS_URL" => ws_url,
              "ITERATIONS" => config.iterations_per_vu.to_s,
              "BENCH_TIER" => config.tier,
              "NUM_USERS" => config.num_users.to_s,
              "BENCH_VUS" => config.env.fetch("BENCH_VUS", ""),
              "PUMA_WORKERS" => config.puma_workers.to_s,
              "PUMA_THREADS" => config.puma_threads.to_s,
              "LISTEN_BACKLOG" => config.listen_backlog.to_s,
              "WRITER_RATIO" => config.env.fetch("WRITER_RATIO", "20"),
              "WRITES_PER_VU" => config.env.fetch("WRITES_PER_VU", ""),
              "FEATURED_WRITERS" => config.env.fetch("FEATURED_WRITERS", ""),
              "IVAR_FEED_STEADY_S" => config.env.fetch("IVAR_FEED_STEADY_S", ""),
              "WRITES_TO_SUBSCRIBED_ROWS_FRACTION" => config.env.fetch("WRITES_TO_SUBSCRIBED_ROWS_FRACTION", ""),
              "K6_SUMMARY_PATH" => "results/#{summary_file}"
            }
          end

          def timeout_failure(timeout_seconds, scenario_name)
            warn "Smoke k6 scenario exceeded #{timeout_seconds}s: #{scenario_name}"
            124
          end

          def capacity_failure(scenario_name)
            warn "\n== CAPACITY GATE FAILED: #{scenario_name} =="
            warn "  k6 threshold violation - the local host could not sustain setup pressure at the scenario's VU target."
            99
          end

          def run_logged(command, log:, chdir:, env:, unset:)
            FileUtils.mkdir_p(File.dirname(log))
            command_env = env.dup
            unset.each { |key| command_env[key] = nil }

            status = nil
            File.open(log, "w") do |file|
              Open3.popen2e(command_env, *command, chdir: chdir, unsetenv_others: false) do |_stdin, out, wait_thr|
                out.each_line do |line|
                  print line
                  file.write(line)
                end
                status = wait_thr.value.exitstatus
              end
            end
            status || 1
          end
      end
    end
  end
end
