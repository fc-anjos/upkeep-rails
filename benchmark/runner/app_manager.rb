# frozen_string_literal: true

require "fileutils"

module Upkeep
  module Benchmark
    module Runner
      class AppManager
        attr_reader :config, :metrics_collector, :process_manager

        def initialize(config, metrics_collector:, process_manager:)
          @config = config
          @metrics_collector = metrics_collector
          @process_manager = process_manager
        end

        def setup(app_dir, role)
          puts "-- Setting up #{File.basename(app_dir)} --"
          with_app_bundle(app_dir, "bundle", "install", "--quiet")

          setup_env = {
            "NUM_USERS" => config.num_users.to_s,
            "LOW_SHARING_BOARDS" => config.env.fetch("LOW_SHARING_BOARDS", "0"),
            "SECRET_KEY_BASE" => config.bench_secret_key_base
          }
          with_app_bundle(app_dir, "env", *setup_env.map { |key, value| "#{key}=#{value}" }, "bundle", "exec", "bin/rails", "db:create", "RAILS_ENV=benchmark", allow_failure: true, quiet: true)
          with_app_bundle(app_dir, "env", *setup_env.map { |key, value| "#{key}=#{value}" }, "bundle", "exec", "bin/rails", "db:migrate", "db:seed", "RAILS_ENV=benchmark")
        end

        def start(app_dir, port, role)
          log_file = File.join(config.results_dir, "#{File.basename(app_dir)}-server-#{config.timestamp}.log")
          pidfile = File.join(app_dir, "tmp/pids/server.pid")
          launcher = File.join(app_dir, "tmp/pids/launcher.pid")
          FileUtils.mkdir_p(File.dirname(pidfile))
          FileUtils.rm_f(pidfile)
          puts "-- Starting #{File.basename(app_dir)} on port #{port} (BENCH=1) --"

          pid = Process.spawn(
            command_env_for(app_dir, role),
            "bundle", "exec", "bin/rails", "server", "-p", port.to_s, "-e", "benchmark",
            chdir: app_dir,
            out: log_file,
            err: [ :child, :out ],
            unsetenv_others: false
          )
          File.write(launcher, pid.to_s)

          wait_for_http!("http://localhost:#{port}/up", retries: 45, log_file: log_file, label: File.basename(app_dir))
          puts "✓ #{File.basename(app_dir)} running on port #{port} (log: #{log_file})"
        end

        def stop(app_dir)
          process_manager.stop_pidfile_process(File.join(app_dir, "tmp/pids/server.pid"), app_dir, File.basename(app_dir))
          process_manager.stop_pidfile_process(File.join(app_dir, "tmp/pids/launcher.pid"), app_dir, "#{File.basename(app_dir)} launcher")
          puts "✓ Stopped #{File.basename(app_dir)}"
        end

        private
          def command_env_for(app_dir, role)
            {
              "BUNDLE_GEMFILE" => File.join(app_dir, "Gemfile"),
              "BENCH" => "1",
              "WEB_CONCURRENCY" => config.puma_workers.to_s,
              "RAILS_MAX_THREADS" => config.puma_threads.to_s,
              "SECRET_KEY_BASE" => config.bench_secret_key_base
            }.merge(database_env_for(role)).merge(relay_env_for(role))
          end

          def relay_env_for(role)
            return {} unless role == "upkeep"

            {
              "UPKEEP_BROKER_SOCKET_PATH" => config.upkeep_broker_socket,
              "UPKEEP_METRICS_PORT" => config.relay_metrics_port.to_s,
              "UPKEEP_METRICS_BIND_ADDRESS" => "127.0.0.1",
              "UPKEEP_WS_BIND" => "127.0.0.1",
              "UPKEEP_WS_PORT" => config.relay_ws_port.to_s,
              "UPKEEP_SIGNED_STREAM_VERIFIER_KEY" => config.bench_secret_key_base
            }
          end

          def database_env_for(role)
            role == "upkeep" ? { "UPKEEP_BENCH_DATABASE" => config.upkeep_database } : { "TURBO_BENCH_DATABASE" => config.turbo_database }
          end

          def with_app_bundle(app_dir, *command, allow_failure: false, quiet: false)
            command_env = { "BUNDLE_GEMFILE" => File.join(app_dir, "Gemfile") }
            out = quiet ? File::NULL : $stdout
            err = quiet ? File::NULL : $stderr
            ok = system(command_env, *command, chdir: app_dir, out: out, err: err, unsetenv_others: false)
            raise "command failed in #{app_dir}: #{command.join(" ")}" unless ok || allow_failure
            ok
          end

          def wait_for_http!(url, retries:, log_file:, label:)
            retries.times do
              return if metrics_collector.fetch_http(url, timeout: 2)
              sleep 1
            end

            warn "ERROR: #{label} failed to start at #{url}"
            warn File.readlines(log_file).last(30).join if File.exist?(log_file)
            exit 1
          end
      end
    end
  end
end
