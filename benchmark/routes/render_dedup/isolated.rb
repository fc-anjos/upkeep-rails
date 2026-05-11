# frozen_string_literal: true

# Isolated render-dedup benchmark profile — explicit inverse of
# shared_identity_free.rb.
#
# Drives `benchmark/k6/render_dedup/isolated.js` with N VUs, each
# subscribed to their own per-user board. Every VU is also a writer.
# The expected dispatch shape is:
#   - render_groups_total ≈ N (one group per (url, fragment, locals))
#   - render_dedup_savings_total ≈ 0
#   - dedup_ratio ≈ 0.0
#   - deliveries / render_groups ≈ 1.0
#
# This is the regression-guard direction. shared_identity_free proves dedup
# works when sharing is high; isolated proves the relay does not
# *fake* dedup when sharing is genuinely absent. A change that
# accidentally collapses per-sub renders into one group across distinct
# subscription_urls would push the ratio above 1.0 here and trip this
# gate.
#
# Invoked from `benchmark/bin/run` for
# `BENCH_FAMILY=render_dedup BENCH_WORKLOAD=isolated`.
# Requires the seed to have been built with `LOW_SHARING_BOARDS=N` so
# the per-user boards exist; the launcher passes that through.
#
# Exit codes: 0 on success (ratio within [0.95, 1.10]), 2 on G-low fail
# (ratio outside that band, or zero render groups observed),
# 1 on infrastructure error.

require "json"
require "net/http"
require "optparse"
require "uri"

require_relative "shared_identity_free"

module Upkeep
  module Benchmark
    class Isolated
      # Acceptable ratio band. Lower bound is below 1.0 to absorb
      # delivery races where the relay has issued a render group but
      # the writer's frame hasn't been counted yet at scrape time. Upper
      # bound is intentionally tight — anything > 1.10 means dedup is
      # collapsing renders across distinct subscription_urls, which is
      # the bug this gate guards against.
      RATIO_MIN = 0.95
      RATIO_MAX = 1.10

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
        run_k6!
        post = scrape_metrics

        report = build_report(pre, post)
        write_report(report)
        print_report(report)

        if post.empty?
          warn("[isolated] dispatch /metrics scrape returned no data — check #{@metrics_url}")
          1
        elsif report[:render_requests].zero?
          warn("[isolated] zero render groups observed — k6 traffic never reached dispatch (check k6 log; verify LOW_SHARING_BOARDS was passed to the seed)")
          2
        elsif report[:ratio] && report[:ratio].between?(RATIO_MIN, RATIO_MAX)
          0
        else
          warn("[isolated] ratio #{report[:ratio]} outside [#{RATIO_MIN}, #{RATIO_MAX}] — dedup is folding renders across distinct subscription_urls (bug) or the writer never received a frame (infra)")
          2
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
        warn("[isolated] metrics scrape failed: #{e.class}: #{e.message}")
        {}
      end

      def run_k6!
        env = {
          "BASE_URL" => @base_url,
          "WS_URL" => @ws_url,
          "BENCH_VUS" => @vus.to_s
        }
        cmd = [ "k6", "run", k6_script ]
        log_file = File.join(@results_dir, "render-dedup-isolated-k6-#{@timestamp}.log")
        FileUtils.mkdir_p(@results_dir)

        pid = Process.spawn(env, *cmd, out: log_file, err: [ :child, :out ])
        _, status = Process.waitpid2(pid)
        return if status.success?
          warn("[isolated] k6 exited non-zero (#{status.exitstatus}); see #{log_file}")
      end

      def k6_script
        File.expand_path("../../k6/render_dedup/isolated.js", __dir__)
      end

      def build_report(pre, post)
        req_pre = sum_counter(pre, "upkeep_relay_render_groups_total")
        req_post = sum_counter(post, "upkeep_relay_render_groups_total")
        req_delta = req_post - req_pre

        savings_pre = sum_counter(pre, "upkeep_relay_render_dedup_savings_total")
        savings_post = sum_counter(post, "upkeep_relay_render_dedup_savings_total")
        savings_delta = savings_post - savings_pre

        deliveries_delta = savings_delta + req_delta
        ratio = req_delta.positive? ? deliveries_delta.to_f / req_delta : nil

        {
          vus: @vus,
          render_requests: req_delta,
          deliveries: deliveries_delta,
          dedup_savings: savings_delta,
          ratio: ratio,
          metrics_url: @metrics_url,
          timestamp: @timestamp
        }
      end

      def sum_counter(parsed, name)
        entries = parsed[name]
        return 0 if entries.nil? || entries.empty?

        entries.values.sum.to_i
      end

      def write_report(report)
        out = File.join(@results_dir, "render-dedup-isolated-#{@timestamp}.json")
        File.write(out, JSON.pretty_generate(report))
      end

      def print_report(report)
        puts ""
        puts "══ render_dedup/isolated result ══"
        puts "  VUs:              #{report[:vus]}"
        puts "  Render groups:    #{report[:render_requests]}"
        puts "  Deliveries:       #{report[:deliveries]}"
        puts "  Dedup savings:    #{report[:dedup_savings]}"
        if report[:ratio]
          puts format("  Ratio (deliv/req): %.2f  (expected: %.2f..%.2f)", report[:ratio], RATIO_MIN, RATIO_MAX)
        else
          puts "  Ratio: n/a (no render groups observed)"
        end
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

  exit Upkeep::Benchmark::Isolated.new(**opts).run
end
