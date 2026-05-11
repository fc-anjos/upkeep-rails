# frozen_string_literal: true

# Shared-identity-free render-dedup benchmark.
#
# Drives the k6 scenario
# `benchmark/k6/render_dedup/shared_identity_free.js` with N=50 VUs
# subscribed to the same `/feed` page, samples the dispatch
# `/metrics` endpoint before and after the run, and emits the headline
# ratio `deliveries / render_groups`. A ratio >= 5 satisfies the G7
# criterion in plan 008.
#
# Invoked from `benchmark/bin/run` for
# `BENCH_FAMILY=render_dedup BENCH_WORKLOAD=shared_identity_free`.
# The benchmark exercises the dispatch render path: one shared update
# should produce one render group and one delivery per subscriber.
#
# Usage:
#   bundle exec ruby benchmark/routes/render_dedup/shared_identity_free.rb \
#     --base-url=http://localhost:3000 \
#     --ws-url=ws://localhost:3000/cable \
#     --metrics-url=http://127.0.0.1:9394/metrics \
#     --vus=50 \
#     --results-dir=benchmark/results \
#     --timestamp=20260417120000
#
# All flags have env-var fallbacks (BENCH_BASE_URL, BENCH_WS_URL,
# RELAY_METRICS_URL, BENCH_VUS, BENCH_RESULTS_DIR, BENCH_TIMESTAMP).
# Exit codes: 0 on success, 2 when the ratio is below 5 (G7 fail), 1 on
# infrastructure error.

require "json"
require "fileutils"
require "net/http"
require "optparse"
require "uri"
require_relative "../../shared/prom_parse"

module Upkeep
  module Benchmark
    class SharedIdentityFree
      RENDER_REQUEST_METRICS = %w[
        upkeep_relay_render_groups_total
      ].freeze
      DEDUP_SAVINGS_METRIC = "upkeep_relay_render_dedup_savings_total"

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

        if report[:ratio] && report[:ratio] >= 5.0
          0
        elsif post.empty?
          warn("[shared_identity_free] dispatch /metrics scrape returned no data — check #{@metrics_url}")
          1
        elsif report[:render_requests].zero?
          warn("[shared_identity_free] zero render groups observed — k6 traffic never reached dispatch (check k6 log for HTTP errors and verify /feed is reachable)")
          2
        else
          warn("[shared_identity_free] ratio #{report[:ratio]} < 5 (gate fails)")
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
        warn("[shared_identity_free] metrics scrape failed: #{e.class}: #{e.message}")
        {}
      end

      def run_k6!
        env = {
          "BASE_URL" => @base_url,
          "WS_URL" => @ws_url,
          "BENCH_VUS" => @vus.to_s
        }
        cmd = [ "k6", "run", k6_script ]
        log_file = File.join(@results_dir, "render-dedup-shared-identity-free-k6-#{@timestamp}.log")
        FileUtils.mkdir_p(@results_dir)

        pid = Process.spawn(env, *cmd, out: log_file, err: [ :child, :out ])
        _, status = Process.waitpid2(pid)
        return if status.success?
          warn("[shared_identity_free] k6 exited non-zero (#{status.exitstatus}); see #{log_file}")
      end

      def k6_script
        File.expand_path("../../k6/render_dedup/shared_identity_free.js", __dir__)
      end

      def build_report(pre, post)
        # Count total render groups (sum across size_buckets): the
        # coordinator emits exactly one group per (url, frag, digest)
        # per invalidation.
        req_pre = sum_counter(pre, "upkeep_relay_render_groups_total")
        req_post = sum_counter(post, "upkeep_relay_render_groups_total")
        req_delta = req_post - req_pre

        savings_pre = sum_counter(pre, DEDUP_SAVINGS_METRIC)
        savings_post = sum_counter(post, DEDUP_SAVINGS_METRIC)
        savings_delta = savings_post - savings_pre

        # Deliveries = savings + requests, because
        # render_dedup_savings_total = (subs_served - requests_issued).
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
        out = File.join(@results_dir, "render-dedup-shared-identity-free-#{@timestamp}.json")
        File.write(out, JSON.pretty_generate(report))
      end

      def print_report(report)
        puts ""
        puts "══ render_dedup/shared_identity_free result ══"
        puts "  VUs:              #{report[:vus]}"
        puts "  Render groups:    #{report[:render_requests]}"
        puts "  Deliveries:       #{report[:deliveries]}"
        puts "  Dedup savings:    #{report[:dedup_savings]}"
        if report[:ratio]
          puts format("  Ratio (deliv/req): %.2f  (G7 threshold: >=5.0)", report[:ratio])
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

  exit Upkeep::Benchmark::SharedIdentityFree.new(**opts).run
end
