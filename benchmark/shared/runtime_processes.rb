# frozen_string_literal: true

# Process sampler used by the benchmark runner. It depends only on the
# standard library because the runner invokes it in a lightweight loop.

require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

module Upkeep
  module Benchmark
    class RuntimeProcesses
      def self.sample_rss(app_pidfile:, output:, metrics_url: nil, app_role_prefix: nil)
        app_root_pid = read_pid(app_pidfile)
        app_pids = collect_tree(app_root_pid)
        app_rss = sum_rss(app_pids)
        now = Time.now.utc

        record = {
          ts: now.iso8601,
          timestamp: (now.to_f * 1000).round,
          app_rss_kb: app_rss,
          combined_rss_kb: app_rss,
          app_pids: app_pids,
          processes: process_breakdown(
            app_root_pid: app_root_pid,
            app_pids: app_pids,
            app_role_prefix: app_role_prefix
          )
        }
        record[:dispatch_metrics] = fetch_counters(metrics_url) if metrics_url

        File.open(output, "a") { |file| file.puts(JSON.generate(record)) }
        record
      end

      def self.read_pid(path)
        return nil unless path && File.exist?(path)

        Integer(File.read(path).strip)
      rescue ArgumentError
        nil
      end

      # Return [pid, *descendants] for the given parent pid. Uses `pgrep -P`
      # recursively, which is available on Linux and macOS.
      def self.collect_tree(root_pid)
        return [] if root_pid.nil?

        tree = [ root_pid ]
        stack = [ root_pid ]
        until stack.empty?
          parent = stack.shift
          children = `pgrep -P #{parent} 2>/dev/null`.split.map(&:to_i)
          children.each do |child|
            next if tree.include?(child)

            tree << child
            stack << child
          end
        end
        tree
      end

      def self.sum_rss(pids)
        return 0 if pids.empty?

        out = `ps -o rss= -p #{pids.join(",")} 2>/dev/null`
        out.split.sum(&:to_i)
      end

      def self.process_breakdown(app_root_pid:, app_pids:, app_role_prefix:)
        app_role_prefix ||= "app"
        process_details(app_pids).map do |detail|
          role = if render_runtime_process?(detail)
            "#{app_role_prefix}_render_runtime"
          elsif detail[:pid] == app_root_pid
            "#{app_role_prefix}_puma_master"
          else
            "#{app_role_prefix}_puma_worker"
          end

          {
            role: role,
            pid: detail[:pid],
            rss_kb: detail[:rss_kb],
            command: detail[:command]
          }
        end
      end

      def self.render_runtime_process?(detail)
        detail[:command].to_s.include?("upkeep-render-runtime")
      end

      def self.process_details(pids)
        return [] if pids.empty?

        out = `ps -o pid= -o rss= -o command= -p #{pids.join(",")} 2>/dev/null`
        out.each_line.each_with_object([]) do |line, details|
          match = line.chomp.match(/\A\s*(\d+)\s+(\d+)\s+(.*)\z/)
          next details unless match

          details << {
            pid: match[1].to_i,
            rss_kb: match[2].to_i,
            command: match[3]
          }
        end
      end

      def self.fetch_counters(metrics_url)
        uri = URI(metrics_url)
        Net::HTTP.start(uri.hostname, uri.port, open_timeout: 1, read_timeout: 1) do |http|
          response = http.get(uri.path.empty? ? "/metrics" : uri.path)
          return nil unless response.is_a?(Net::HTTPSuccess)

          {
            render_groups_total: line_sum(response.body, "upkeep_relay_render_groups_total"),
            render_dedup_savings_total: line_sum(response.body, "upkeep_relay_render_dedup_savings_total"),
            invalidation_events_total: line_sum(response.body, "upkeep_relay_invalidation_events_total"),
            delivery_skipped_unchanged_total: line_sum(response.body, "upkeep_relay_delivery_skipped_unchanged_total")
          }
        end
      rescue StandardError
        nil
      end

      def self.line_sum(body, metric_name)
        total = 0
        body.each_line do |line|
          next unless line.start_with?(metric_name)
          next if line.start_with?(metric_name + "_")

          match = line.match(/\A#{Regexp.escape(metric_name)}(?:\{[^}]*\})?\s+(\S+)\z/)
          total += Float(match[1]).to_i if match
        end
        total
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  subcommand = ARGV.shift or abort("usage: runtime_processes.rb <sample> [options]")

  case subcommand
  when "sample"
    opts = {}
    OptionParser.new do |option|
      option.on("--app-pidfile=PATH") { |value| opts[:app_pidfile] = value }
      option.on("--output=PATH") { |value| opts[:output] = value }
      option.on("--metrics-url=URL") { |value| opts[:metrics_url] = value }
      option.on("--app-role-prefix=NAME") { |value| opts[:app_role_prefix] = value }
    end.parse!
    record = Upkeep::Benchmark::RuntimeProcesses.sample_rss(**opts)
    puts JSON.generate(record)
  else
    abort("unknown subcommand: #{subcommand}")
  end
end
