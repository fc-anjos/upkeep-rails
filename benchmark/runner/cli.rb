# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "rbconfig"
require "shellwords"
require "timeout"
require "uri"

require_relative "app_manager"
require_relative "config"
require_relative "k6_runner"
require_relative "metrics_collector"
require_relative "process_manager"
require_relative "workload_executor"
require_relative "workload_registry"

module Upkeep
  module Benchmark
    module Runner
      class CLI
        def self.call(argv)
          new(argv).call
        rescue WorkloadError => error
          warn "ERROR: #{error.message}"
          1
        end

        attr_reader :argv, :env, :bench_dir, :results_dir, :timestamp

        def initialize(argv, env: ENV)
          @argv = argv
          @env = env
          @bench_dir = File.expand_path("..", __dir__)
          @results_dir = File.join(@bench_dir, "results")
          @timestamp = env.fetch("BENCH_TIMESTAMP") { Time.now.strftime("%Y%m%d%H%M%S") }
          parse_cli!
          initialize_config!
        end

        def call
          FileUtils.mkdir_p(results_dir)
          return 1 unless check_prereqs

          if workload.top_level == "render_parallelism_sweep"
            return run_render_parallelism_sweep
          elsif workload.top_level == "memory_ceiling_topology_sweep"
            return run_memory_ceiling_topology_sweep
          end

          trap_signals
          prepare_benchmark_environment
          print_header

          if workload.key == "matrix/pipeline_smoke"
            run_smoke_pipeline
          else
            run_comparison
          end
        ensure
          cleanup_benchmark_processes if @cleanup_enabled
        end

        private
          attr_reader :config, :workload

          def parse_cli!
            OptionParser.new do |parser|
              parser.on("--family=FAMILY") { |value| env["BENCH_FAMILY"] = value }
              parser.on("--workload=WORKLOAD") { |value| env["BENCH_WORKLOAD"] = value }
              parser.on("--tier=TIER") { |value| env["BENCH_TIER"] = value }
            end.parse!(argv)
          end

          def initialize_config!
            @config = Config.new(env: env, bench_dir: bench_dir, timestamp: timestamp)
            @cold_capacity_failures = []
            @bench_exit = 0
            @cleanup_enabled = false
            @workload = WorkloadRegistry.new(config).resolve
          end

          def run_smoke_pipeline
            smoke_progress("setup", "seeding #{File.basename(upkeep_app_dir)}")
            setup_app(upkeep_app_dir, "upkeep")
            smoke_progress("sockets", "preparing runtime socket")
            prepare_runtime_sockets
            smoke_progress("boot", "starting #{File.basename(upkeep_app_dir)}")
            start_app(upkeep_app_dir, upkeep_port, "upkeep")
            smoke_progress("metrics", "capturing baseline metrics")
            poll_metrics(upkeep_port, "upkeep", "before")
            smoke_progress("load", "running k6 smoke scenario")
            run_k6("matrix/board_upkeep.js", "http://localhost:#{upkeep_port}", "ws://localhost:#{relay_ws_port}", "Smoke e2e - board_upkeep")
            smoke_progress("metrics", "capturing final metrics")
            poll_metrics(upkeep_port, "upkeep", "final")
            smoke_progress("shutdown", "stopping #{File.basename(upkeep_app_dir)}")
            stop_app(upkeep_app_dir, "upkeep")
            smoke_progress("summary", "writing smoke summary")
            run_ruby(File.join(bench_dir, "smoke_summary.rb"), results_dir, timestamp)
            summary_path = File.join(results_dir, "smoke-#{timestamp}.md")
            smoke_progress("assert", "asserting dedup thresholds")
            run_ruby(File.join(bench_dir, "assert_dedup.rb"), summary_path)
            smoke_progress("done", summary_path)
            puts "\nSmoke summary: #{summary_path}"
            0
          end

          def run_comparison
            setup_app(upkeep_app_dir, "upkeep")
            setup_app(turbo_app_dir, "turbo") if workload.needs_turbo
            prepare_runtime_sockets
            start_app(upkeep_app_dir, upkeep_port, "upkeep")
            start_app(turbo_app_dir, turbo_port, "turbo") if workload.needs_turbo
            start_rss_sampler
            start_turbo_rss_sampler if workload.key == "memory_ceiling/shared_feed_churn" && workload.needs_turbo
            poll_metrics(upkeep_port, "upkeep", "before")
            poll_metrics(turbo_port, "turbo", "before") if workload.needs_turbo

            status = if workload.route_script
              run_route_workload
            else
              run_named_workload
            end
            return status unless status.zero?

            poll_metrics(upkeep_port, "upkeep", "final")
            poll_metrics(turbo_port, "turbo", "final") if workload.needs_turbo
            stop_runtime
            generate_report
            capacity_exit
          end

          def run_route_workload
            if workload.key == "render_dedup/isolated" && integer_env("LOW_SHARING_BOARDS", 0) < workload.vus
              warn "ERROR: render_dedup/isolated requires LOW_SHARING_BOARDS >= BENCH_VUS (have #{workload.vus} VUs, #{env.fetch("LOW_SHARING_BOARDS", "0")} boards seeded)."
              return 1
            end

            # Leave the apps running so `run_comparison` can poll final
            # metrics before stop_runtime.
            status = run_route_benchmark(workload.route_script, workload.vus)
            poll_metrics(upkeep_port, "upkeep", workload.post_label)
            puts "\nResults in: #{results_dir}/"
            status
          end

          def run_named_workload
            status = workload_executor.run_named_workload
            @cold_capacity_failures.concat(workload_executor.cold_capacity_failures)
            status
          end

          def setup_app(app_dir, role)
            app_manager.setup(app_dir, role)
          end

          def start_app(app_dir, port, role)
            app_manager.start(app_dir, port, role)
          end

          def stop_app(app_dir, _role)
            app_manager.stop(app_dir)
          end

          def prepare_benchmark_environment
            @cleanup_enabled = true
            cleanup_stale_benchmark_state
            assert_listener_clear(k6_api_port, "k6 local API")
            assert_listener_clear(relay_metrics_port, "upkeep dispatch metrics")
            assert_listener_clear(relay_ws_port, "upkeep dispatch websocket")
            assert_listener_clear(upkeep_port, File.basename(upkeep_app_dir))
            assert_listener_clear(turbo_port, File.basename(turbo_app_dir)) if workload.needs_turbo
          end

          def prepare_runtime_sockets
            FileUtils.mkdir_p(File.dirname(upkeep_broker_socket))
            FileUtils.rm_f(upkeep_broker_socket)
          end

          def poll_metrics(port, app_name, label)
            metrics_collector.poll(port, app_name, label)
          end

          def run_k6(script, base_url, ws_url, scenario_name, capacity_gate: false, timeout_seconds: nil)
            k6_runner.run(script, base_url, ws_url, scenario_name, capacity_gate: capacity_gate, timeout_seconds: timeout_seconds)
          end

          def run_route_benchmark(script, vus)
            command_env = {
              "BENCH_RESULTS_DIR" => results_dir,
              "BENCH_TIMESTAMP" => timestamp
            }
            system_status(
              command_env,
              ruby, script,
              "--base-url=http://localhost:#{upkeep_port}",
              "--ws-url=ws://localhost:#{relay_ws_port}",
              "--metrics-url=#{relay_metrics_url}",
              "--vus=#{vus}",
              "--results-dir=#{results_dir}",
              "--timestamp=#{timestamp}"
            )
          end

          def run_render_parallelism_sweep
            values = env.fetch("UPKEEP_RENDER_CONCURRENCY_SWEEP", "1,2,5,10,20")
            vus = workload.vus || 50
            statuses = []
            child_timestamps = []
            puts "Render parallelism sweep"
            values.split(",").each do |concurrency|
              child_timestamp = "#{timestamp}-render-c#{concurrency}"
              child_timestamps << child_timestamp
              statuses << system_status({
                "BENCH" => "1",
                "BENCH_FAMILY" => "render_dedup",
                "BENCH_WORKLOAD" => "isolated",
                "BENCH_TIER" => tier,
                "BENCH_VUS" => vus.to_s,
                "LOW_SHARING_BOARDS" => vus.to_s,
                "PUMA_WORKERS" => puma_workers.to_s,
                "PUMA_THREADS" => puma_threads.to_s,
                "UPKEEP_RENDER_CONCURRENCY" => concurrency,
                "BENCH_TIMESTAMP" => child_timestamp
              }, File.join(bench_dir, "bin/run"))
            end
            run_ruby(File.join(bench_dir, "render_parallelism_sweep_report.rb"), results_dir, timestamp, values, child_timestamps.join(" "), statuses.join(" "))
            statuses.find { |status| status != 0 } || 0
          end

          def run_memory_ceiling_topology_sweep
            system_status(
              {},
              ruby, File.join(bench_dir, "routes/memory_ceiling/topology_sweep.rb"),
              "--bench-dir=#{bench_dir}",
              "--results-dir=#{results_dir}",
              "--timestamp=#{timestamp}",
              "--tier=#{tier}",
              "--vus=#{workload.vus}",
              "--writes-per-vu=#{env.fetch("WRITES_PER_VU", "3")}",
              "--rss-sample-interval=#{rss_sample_interval}"
            )
          end

          def generate_report
            case workload.key
            when "memory_ceiling/shared_feed_churn"
              puts "\n== Generating memory ceiling report =="
              run_ruby(File.join(bench_dir, "memory_ceiling_report.rb"), results_dir, timestamp)
              puts "\nResults in: #{results_dir}/"
              puts "Memory report: #{File.join(results_dir, "memory-ceiling-shared-feed-churn-#{timestamp}.md")}"
            when "render_dedup/featured_item_compare"
              puts "\n== Generating featured-item compare report =="
              run_ruby(File.join(bench_dir, "featured_item_compare_report.rb"), results_dir, timestamp)
              puts "\nResults in: #{results_dir}/"
              puts "Compare report: #{File.join(results_dir, "featured-item-compare-#{timestamp}.md")}"
            else
              puts "\n== Generating matrix comparison report =="
              run_ruby(File.join(bench_dir, "compare.rb"), results_dir, timestamp)
              puts "\nResults in: #{results_dir}/"
              puts "Comparison: #{File.join(results_dir, "matrix-compare-#{timestamp}.md")}"
            end
          end

          def capacity_exit
            if @cold_capacity_failures.any?
              puts "\n== CAPACITY GATE FAILED (#{@cold_capacity_failures.join(" ")}) =="
              @bench_exit = 99
            end
            @bench_exit
          end

          def start_rss_sampler
            start_rss_sampler_for(
              "upkeep-app",
              File.join(upkeep_app_dir, "tmp/pids/launcher.pid"),
              File.join(results_dir, "rss-#{timestamp}.jsonl"),
              File.join(results_dir, "rss-sampler-#{timestamp}.pid"),
              relay_metrics_url,
              "upkeep"
            )
          end

          def start_turbo_rss_sampler
            start_rss_sampler_for(
              "turbo-app",
              File.join(turbo_app_dir, "tmp/pids/launcher.pid"),
              File.join(results_dir, "rss-turbo-#{timestamp}.jsonl"),
              File.join(results_dir, "rss-sampler-turbo-#{timestamp}.pid"),
              nil,
              "turbo"
            )
          end

          def start_rss_sampler_for(label, app_pidfile, output, pidfile, metrics_url, app_role_prefix)
            FileUtils.mkdir_p(File.dirname(output))
            File.write(output, "")
            pid = Process.spawn(
              ruby, "-I#{File.join(bench_dir, "shared")}", "-e",
              rss_sampler_code(app_pidfile, output, metrics_url, app_role_prefix),
              out: File::NULL,
              err: File::NULL
            )
            File.write(pidfile, pid.to_s)
            puts "✓ RSS sampler (#{label}) pid=#{pid} (log: #{output}, interval=#{rss_sample_interval}s)"
          end

          def rss_sampler_code(app_pidfile, output, metrics_url, app_role_prefix)
            <<~RUBY
              require "runtime_processes"
              loop do
                Upkeep::Benchmark::RuntimeProcesses.sample_rss(
                  app_pidfile: #{app_pidfile.inspect},
                  output: #{output.inspect},
                  metrics_url: #{metrics_url.inspect},
                  app_role_prefix: #{app_role_prefix.inspect}
                ) rescue nil
                sleep #{rss_sample_interval}
              end
            RUBY
          end

          def stop_runtime
            stop_rss_samplers
            stop_app(upkeep_app_dir, "upkeep")
            stop_app(turbo_app_dir, "turbo") if workload.needs_turbo
          end

          def stop_rss_samplers
            Dir[File.join(results_dir, "rss-sampler-*.pid")].each do |pidfile|
              stop_pidfile_process(pidfile, bench_dir, "RSS sampler")
            end
          end

          def cleanup_benchmark_processes
            cleanup_stale_benchmark_state
          end

          def cleanup_stale_benchmark_state
            [ upkeep_app_dir, turbo_app_dir ].uniq.each do |app_dir|
              stop_pidfile_process(File.join(app_dir, "tmp/pids/server.pid"), app_dir, File.basename(app_dir))
              stop_pidfile_process(File.join(app_dir, "tmp/pids/launcher.pid"), app_dir, "#{File.basename(app_dir)} launcher")
            end
            stop_rss_samplers
            stop_owned_pattern_processes("k6 run", bench_dir, "benchmark k6 process(es)")
            FileUtils.rm_f(upkeep_broker_socket)
          end

          def stop_pidfile_process(pidfile, expected_cwd, label)
            process_manager.stop_pidfile_process(pidfile, expected_cwd, label)
          end

          def stop_owned_pattern_processes(pattern, expected_cwd, label)
            process_manager.stop_owned_pattern_processes(pattern, expected_cwd, label)
          end

          def assert_listener_clear(port, label)
            process_manager.assert_listener_clear(port, label)
          end

          def check_prereqs
            missing = %w[k6 redis-cli ruby bundle curl].reject { |cmd| system("command", "-v", cmd, out: File::NULL, err: File::NULL) }
            missing << "redis" unless system("redis-cli", "ping", out: File::NULL, err: File::NULL)
            return true if missing.empty?

            warn "ERROR: missing prerequisites: #{missing.join(", ")}"
            false
          end

          def print_header
            puts "Upkeep vs Turbo Benchmark"
            puts "================================"
            puts "Family:    #{family}"
            puts "Workload:  #{workload_name}"
            puts "Tier:      #{tier}"
            puts "Mode:      #{upkeep_only? ? "upkeep-only" : "comparison"}"
            puts "Timestamp: #{timestamp}"
            puts "Puma:      #{puma_workers} workers x #{puma_threads} threads"
            puts "Users:     #{num_users}"
            puts "Ports:     upkeep=#{upkeep_port} turbo=#{turbo_port} k6=#{k6_api_port} dispatch_ws=#{relay_ws_port} dispatch_metrics=#{relay_metrics_port}"
            puts ""
          end

          def smoke_progress(stage, detail = "")
            return unless smoke_progress_file && !smoke_progress_file.empty?

            FileUtils.mkdir_p(File.dirname(smoke_progress_file))
            File.write(smoke_progress_file, "#{stage}|#{detail}\n")
          end

          def run_ruby(*args)
            status = system_status({}, ruby, *args)
            raise "ruby command failed: #{args.join(" ")}" unless status.zero?
          end

          def ruby
            RbConfig.ruby
          end

          def system_status(command_env, *command)
            system(command_env, *command, unsetenv_others: false)
            $?.exitstatus || 1
          end

          def run_logged(command, log:, chdir:, env:, unset: [])
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

          def family = config.family
          def workload_name = config.workload_name
          def tier = config.tier
          def upkeep_port = config.upkeep_port
          def turbo_port = config.turbo_port
          def relay_metrics_port = config.relay_metrics_port
          def relay_ws_port = config.relay_ws_port
          def k6_api_port = config.k6_api_port
          def iterations_per_vu = config.iterations_per_vu
          def puma_workers = config.puma_workers
          def puma_threads = config.puma_threads
          def num_users = config.num_users
          def upkeep_app_dir = config.upkeep_app_dir
          def turbo_app_dir = config.turbo_app_dir
          def upkeep_database = config.upkeep_database
          def turbo_database = config.turbo_database
          def relay_metrics_url = config.relay_metrics_url
          def upkeep_broker_socket = config.upkeep_broker_socket
          def bench_secret_key_base = config.bench_secret_key_base
          def rss_sample_interval = config.rss_sample_interval
          def smoke_progress_file = config.smoke_progress_file
          def k6_runner = @k6_runner ||= K6Runner.new(config)
          def metrics_collector = @metrics_collector ||= MetricsCollector.new(config)
          def process_manager = @process_manager ||= ProcessManager.new
          def app_manager = @app_manager ||= AppManager.new(config, metrics_collector: metrics_collector, process_manager: process_manager)
          def workload_executor = @workload_executor ||= WorkloadExecutor.new(config, workload, k6_runner: k6_runner, metrics_collector: metrics_collector)
          def upkeep_only? = config.upkeep_only?
          def integer_env(key, default) = config.integer_env(key, default)
          def listen_backlog = config.listen_backlog

          def trap_signals
            %w[INT TERM].each do |signal|
              trap(signal) do
                cleanup_benchmark_processes
                exit 130
              end
            end
          end
      end
    end
  end
end
