# frozen_string_literal: true

# fallback_contradiction benchmark profile — exercises the per-sid
# runtime-contradiction fallback fan-out instrumented in
# `lib/upkeep/relay/execution/group_executor.rb`.
#
# Drives `benchmark/k6/render_parallelism/fallback_contradiction.js`
# with N authenticated VUs subscribed to `/signed_feed`, whose
# rendered partial reads `Current.user` through an opaque helper.
# The compile-time classifier tags the partial `:none`; runtime
# observation logs the identity read; the atomic delivery gate raises
# ClassificationDowngraded; the dispatcher re-renders per sid.
#
# Acceptance:
#   - classification_downgrades_total delta > 0  (by design)
#   - per_sid_fallback_duration_seconds samples > 0
#   - render_call_errors_total delta == 0
#   - one delivery per VU per write
#
# Comparing this workload at UPKEEP_RENDER_CONCURRENCY=1 vs =10 measures
# whether parallelizing the fallback fan-out reduced the worst-case
# fallback latency. Exit codes: 0 on success, 2 on profile fail, 1 on
# infrastructure error.

require "json"
require "net/http"
require "optparse"
require "uri"
require "fileutils"

require_relative "../render_dedup/shared_identity_free"

module Upkeep
  module Benchmark
    class FallbackContradiction
      def initialize(base_url:, ws_url:, metrics_url:, vus:, results_dir:, timestamp:)
        @base_url = base_url
        @ws_url = ws_url
        @metrics_url = metrics_url
        @vus = vus
        @results_dir = results_dir
        @timestamp = timestamp
      end

      def run
        pre = scrape_metrics
        workload_status = run_workload!
        post = scrape_metrics

        report = build_report(pre, post)
        write_report(report)
        print_report(report)

        if post.empty?
          warn("[fallback_contradiction] dispatch /metrics scrape returned no data — check #{@metrics_url}")
          1
        elsif workload_status != 0
          warn("[fallback_contradiction] workload exited non-zero (#{workload_status})")
          1
        elsif report[:render_call_errors].positive?
          warn("[fallback_contradiction] render_call_errors_total delta = #{report[:render_call_errors]} (must be 0)")
          2
        elsif report[:fallback_samples].zero?
          # The contradiction triggers per-sid fallback through any of
          # the three handler branches (`classification_downgraded`,
          # `render_mode_downgraded`, or generic render_error). We
          # measure the actual fanout (`per_sid_fallback_duration_seconds`)
          # rather than the kind-specific counter so the workload stays
          # honest regardless of which branch the runtime contradiction
          # routes through.
          warn("[fallback_contradiction] zero per_sid_fallback_duration_seconds samples — fallback fanout did not run")
          2
        elsif report[:render_calls_by_mode].fetch("synthetic_request", 0).zero?
          warn("[fallback_contradiction] zero synthetic_request render calls — per-sid fanout did not exercise the synthetic path")
          2
        else
          0
        end
      end

      private

      def scrape_metrics
        uri = URI(@metrics_url)
        Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 2) do |http|
          response = http.get(uri.path.empty? ? "/metrics" : uri.path)
          return PromParse.parse(response.body) if response.is_a?(Net::HTTPSuccess)
        end
        {}
      rescue StandardError => e
        warn("[fallback_contradiction] metrics scrape failed: #{e.class}: #{e.message}")
        {}
      end

      def run_workload!
        env = {
          "BASE_URL" => @base_url,
          "WS_URL" => @ws_url,
          "BENCH_VUS" => @vus.to_s
        }
        cmd = [ "k6", "run", workload_script ]
        log_file = File.join(@results_dir, "render-parallelism-fallback-contradiction-k6-#{@timestamp}.log")
        FileUtils.mkdir_p(@results_dir)

        pid = Process.spawn(env, *cmd, out: log_file, err: [ :child, :out ])
        _, status = Process.waitpid2(pid)
        return 0 if status.success?

        warn("[fallback_contradiction] k6 exited non-zero (#{status.exitstatus}); see #{log_file}")
        status.exitstatus || 1
      end

      def workload_script
        File.expand_path("../../k6/render_parallelism/fallback_contradiction.js", __dir__)
      end

      def build_report(pre, post)
        downgrades = sum_all_labels_delta(pre, post, "upkeep_relay_classification_downgrades_total")
        render_call_errors = sum_all_labels_delta(pre, post, "upkeep_relay_render_call_errors_total")
        groups_total = sum_all_labels_delta(pre, post, "upkeep_relay_render_groups_total")
        fallback_count = sum_all_labels_delta(pre, post, "upkeep_relay_per_sid_fallback_duration_seconds_count")
        fallback_sum = sum_all_labels_float_delta(pre, post, "upkeep_relay_per_sid_fallback_duration_seconds_sum")
        render_calls_by_mode = labelled_delta(pre, post, "upkeep_relay_render_calls_total", "mode")
        runtime_contradictions = sum_all_labels_delta(pre, post, "upkeep_relay_runtime_contradictions_total")
        avg_fallback_ms = fallback_count.positive? ? ((fallback_sum / fallback_count) * 1000).round(2) : nil

        {
          vus: @vus,
          downgrades: downgrades,
          runtime_contradictions: runtime_contradictions,
          render_call_errors: render_call_errors,
          render_groups_total: groups_total,
          fallback_samples: fallback_count,
          fallback_sum_seconds: fallback_sum.round(4),
          fallback_avg_ms: avg_fallback_ms,
          render_calls_by_mode: render_calls_by_mode,
          render_concurrency: ENV.fetch("UPKEEP_RENDER_CONCURRENCY", "1"),
          metrics_url: @metrics_url,
          timestamp: @timestamp
        }
      end

      def sum_all_labels_delta(pre, post, name)
        sum_counter(post, name) - sum_counter(pre, name)
      end

      def sum_all_labels_float_delta(pre, post, name)
        sum_counter_float(post, name) - sum_counter_float(pre, name)
      end

      def sum_counter(parsed, name)
        entries = parsed[name]
        return 0 if entries.nil? || entries.empty?

        entries.values.sum.to_i
      end

      def sum_counter_float(parsed, name)
        entries = parsed[name]
        return 0.0 if entries.nil? || entries.empty?

        entries.values.sum.to_f
      end

      def labelled_delta(pre, post, name, label_key)
        pre_entries = pre[name] || {}
        post_entries = post[name] || {}
        keys = (pre_entries.keys + post_entries.keys).uniq
        keys.each_with_object({}) do |labels, out|
          label_value = labels[label_key]
          next if label_value.nil?
          delta = post_entries[labels].to_i - pre_entries[labels].to_i
          next if delta.zero?
          out[label_value] = (out[label_value] || 0) + delta
        end
      end

      def write_report(report)
        out = File.join(@results_dir, "render-parallelism-fallback-contradiction-#{@timestamp}.json")
        File.write(out, JSON.pretty_generate(report))
      end

      def print_report(report)
        puts ""
        puts "══ render_parallelism/fallback_contradiction result ══"
        puts "  Render concurrency:           #{report[:render_concurrency]}"
        puts "  VUs:                          #{report[:vus]}"
        puts "  Render groups total:          #{report[:render_groups_total]}"
        puts "  Classification downgrades:    #{report[:downgrades]}"
        puts "  Runtime contradictions:       #{report[:runtime_contradictions]}"
        puts "  Render call errors:            #{report[:render_call_errors]}"
        puts "  Fallback samples:             #{report[:fallback_samples]}"
        puts "  Fallback sum:                 #{report[:fallback_sum_seconds]} s"
        puts format("  Fallback avg:                 %.2f ms", report[:fallback_avg_ms]) if report[:fallback_avg_ms]
        puts "  Render calls by mode:          #{report[:render_calls_by_mode].inspect}"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {
    base_url: ENV["BENCH_BASE_URL"] || "http://localhost:3000",
    ws_url: ENV["BENCH_WS_URL"] || "ws://localhost:3000/cable",
    metrics_url: ENV["RELAY_METRICS_URL"] || "http://127.0.0.1:9394/metrics",
    vus: Integer(ENV["BENCH_VUS"] || "50"),
    results_dir: ENV["BENCH_RESULTS_DIR"] || File.expand_path("../../results", __dir__),
    timestamp: ENV["BENCH_TIMESTAMP"] || Time.now.strftime("%Y%m%d%H%M%S")
  }

  OptionParser.new do |o|
    o.on("--base-url=URL") { |v| opts[:base_url] = v }
    o.on("--ws-url=URL") { |v| opts[:ws_url] = v }
    o.on("--metrics-url=URL") { |v| opts[:metrics_url] = v }
    o.on("--vus=N", Integer) { |v| opts[:vus] = v }
    o.on("--results-dir=DIR") { |v| opts[:results_dir] = v }
    o.on("--timestamp=TS") { |v| opts[:timestamp] = v }
  end.parse!

  exit Upkeep::Benchmark::FallbackContradiction.new(**opts).run
end
