# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../shared/relay_metrics_snapshot"

module Upkeep
  module Benchmark
    module Runner
      class MetricsCollector
        attr_reader :config

        def initialize(config)
          @config = config
        end

        def poll(port, app_name, label)
          output_file = File.join(config.results_dir, "metrics-#{app_name}-#{config.timestamp}.jsonl")
          metrics_path = metrics_path_for(app_name, label)
          response = fetch_http("http://localhost:#{port}#{metrics_path}", timeout: config.integer_env("METRICS_CURL_TIMEOUT_SECONDS", 60))

          unless response
            warn "WARN: #{app_name} metrics unreachable at http://localhost:#{port}#{metrics_path} (label=#{label}) - recording empty checkpoint"
            File.open(output_file, "a") { |file| file.puts(JSON.generate(label: label, data: nil, unreachable: true)) }
            return
          end

          data = JSON.parse(response)
          if app_name == "upkeep"
            dispatch_prom = scrape_dispatch_metrics(label)
            data = Upkeep::Benchmark::RelayMetricsSnapshot.merge_into(data, dispatch_prom) if dispatch_prom && !dispatch_prom.empty?
            scrape_dispatch_memory(label)
          end

          File.open(output_file, "a") { |file| file.puts(JSON.generate(label: label, data: data)) }
          puts "  ✓ Polled #{app_name} metrics (#{label})"
        end

        def fetch_http(url, timeout:)
          uri = URI(url)
          Net::HTTP.start(uri.hostname, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
            response = http.get(uri.request_uri)
            return response.body if response.is_a?(Net::HTTPSuccess)
          end
          nil
        rescue StandardError
          nil
        end

        private
          def metrics_path_for(app_name, label)
            return "/bench/metrics" unless app_name == "upkeep"

            case label
            when "before" then "/bench/metrics?memory_phase=before"
            when "after-memory-ceiling-upkeep" then "/bench/metrics?memory_phase=after_drain"
            when "final" then "/bench/metrics?memory_phase=final"
            else "/bench/metrics"
            end
          end

          def scrape_dispatch_metrics(label)
            attempts = label == "before" ? 5 : 1
            attempts.times do |index|
              body = fetch_http(config.relay_metrics_url, timeout: config.integer_env("METRICS_CURL_TIMEOUT_SECONDS", 15))
              return body if body && !body.empty?
              sleep 1 if index < attempts - 1
            end

            raise "dispatch /metrics unreachable at #{config.relay_metrics_url} (label=#{label})"
          end

          def scrape_dispatch_memory(label)
            phase = { "before" => "before", "after-memory-ceiling-upkeep" => "after_drain", "final" => "final" }[label]
            return unless phase

            body = fetch_http("http://127.0.0.1:#{config.relay_metrics_port}/bench/memory?memory_phase=#{phase}", timeout: config.integer_env("METRICS_CURL_TIMEOUT_SECONDS", 15))
            return unless body

            payload = JSON.parse(body)
            payload["event"] = "dispatch_memory_snapshot"
            payload["wall_time_ms"] = (Time.now.to_f * 1000).round(3)
            File.open(File.join(config.results_dir, "dispatch-memory-#{config.timestamp}.jsonl"), "a") { |file| file.puts(JSON.generate(payload)) }
          rescue StandardError => error
            warn "Dispatch memory probe failed (label=#{label}): #{error.message}"
          end
      end
    end
  end
end
