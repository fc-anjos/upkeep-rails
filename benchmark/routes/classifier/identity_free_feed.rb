# frozen_string_literal: true

# identity_free_feed benchmark profile — classifier and request-free
# route validation for a `:none`-tier surface.
#
# Drives `benchmark/k6/classifier/identity_free_feed.js` with N VUs all
# subscribed to the anonymous `/feed` page. Samples dispatch
# `/metrics` endpoint
# before and after and reports the per-tier render-group split,
# downgrade count, and dedup ratio.
#
# Acceptance (all must hold):
#   - render_groups_by_tier{tier="none"}      > 0
#   - render_groups_by_tier{tier="user-keyed"} == 0
#   - render_groups_by_mode{mode="request_free"} > 0
#   - render_groups_by_mode{mode="page_replay"}  == 0
#   - classification_downgrades_total delta   == 0
#   - dedup ratio (savings / subs_served)     >= 0.80 at VUS=50
#
# Invoked from `benchmark/bin/run` for
# `BENCH_FAMILY=classifier BENCH_WORKLOAD=identity_free_feed`.
# Exit codes: 0 on success, 2 on profile fail, 1 on infrastructure
# error.

require "json"
require "net/http"
require "optparse"
require "uri"

require_relative "../render_dedup/shared_identity_free"

module Upkeep
  module Benchmark
    class IdentityFreeFeed
      # Dedup ratio floor. N-1 of N subscribers must be deduplicated per
      # write for the profile to demonstrate identity-free dedup; at N=50 a
      # perfect run is 0.98 and the floor leaves slack for warmup /
      # races. Anything below 0.80 means either the classifier missed
      # the partial (it stayed `:user-keyed`) or the atomic delivery
      # gate tripped.
      DEDUP_RATIO_FLOOR = 0.80

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
          warn("[identity_free_feed] dispatch /metrics scrape returned no data — check #{@metrics_url}")
          1
        elsif report[:render_requests].zero?
          warn("[identity_free_feed] zero render groups observed — k6 traffic never reached dispatch")
          2
        elsif report[:downgrades].positive?
          warn("[identity_free_feed] classification_downgrades_total delta = #{report[:downgrades]} (must be 0)")
          2
        elsif report[:tier_none].zero?
          warn("[identity_free_feed] zero `:none`-tier groups — classifier did not resolve _feed_item.html.erb to :none")
          2
        elsif report[:tier_user_keyed].positive?
          warn("[identity_free_feed] #{report[:tier_user_keyed]} `:user-keyed` groups observed — the feed render path is reading identity state")
          2
        elsif report[:mode_request_free].zero?
          warn("[identity_free_feed] zero request_free groups observed — the feed render path is not taking the cheap render path")
          2
        elsif report[:mode_page_replay].positive?
          warn("[identity_free_feed] #{report[:mode_page_replay]} page_replay groups observed — the feed render path is replaying whole pages")
          2
        elsif report[:ratio] && report[:ratio] >= DEDUP_RATIO_FLOOR
          0
        else
          warn("[identity_free_feed] dedup ratio #{report[:ratio]} < #{DEDUP_RATIO_FLOOR}")
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
        warn("[identity_free_feed] metrics scrape failed: #{e.class}: #{e.message}")
        {}
      end

      def run_k6!
        env = {
          "BASE_URL" => @base_url,
          "WS_URL" => @ws_url,
          "BENCH_VUS" => @vus.to_s
        }
        cmd = [ "k6", "run", k6_script ]
        log_file = File.join(@results_dir, "classifier-identity-free-feed-k6-#{@timestamp}.log")
        FileUtils.mkdir_p(@results_dir)

        pid = Process.spawn(env, *cmd, out: log_file, err: [ :child, :out ])
        _, status = Process.waitpid2(pid)
        return if status.success?
          warn("[identity_free_feed] k6 exited non-zero (#{status.exitstatus}); see #{log_file}")
      end

      def k6_script
        File.expand_path("../../k6/classifier/identity_free_feed.js", __dir__)
      end

      def build_report(pre, post)
        req_delta = counter_delta(pre, post, "upkeep_relay_render_groups_total")
        savings_delta = counter_delta(pre, post, "upkeep_relay_render_dedup_savings_total")
        deliveries_delta = savings_delta + req_delta

        tier_none       = labeled_delta(pre, post, "upkeep_relay_render_groups_by_tier", "tier" => "none")
        tier_user_keyed = labeled_delta(pre, post, "upkeep_relay_render_groups_by_tier", "tier" => "user-keyed")
        mode_request_free = labeled_delta(pre, post, "upkeep_relay_render_groups_by_mode", "mode" => "request_free")
        mode_synthetic_request = labeled_delta(pre, post, "upkeep_relay_render_groups_by_mode", "mode" => "synthetic_request")
        mode_page_replay = labeled_delta(pre, post, "upkeep_relay_render_groups_by_mode", "mode" => "page_replay")
        render_call_request_free = labeled_delta(pre, post, "upkeep_relay_render_calls_total", "mode" => "request_free")
        render_call_synthetic_request = labeled_delta(pre, post, "upkeep_relay_render_calls_total", "mode" => "synthetic_request")
        render_call_page_replay = labeled_delta(pre, post, "upkeep_relay_render_calls_total", "mode" => "page_replay")
        replay_forced = counter_delta(pre, post, "upkeep_relay_replay_forced_groups_total")
        downgrades      = sum_all_labels_delta(pre, post, "upkeep_relay_classification_downgrades_total")

        subs_served = req_delta + savings_delta
        ratio = subs_served.positive? ? (savings_delta.to_f / subs_served).round(4) : nil

        {
          vus: @vus,
          render_requests: req_delta,
          deliveries: deliveries_delta,
          dedup_savings: savings_delta,
          ratio: ratio,
          tier_none: tier_none,
          tier_user_keyed: tier_user_keyed,
          mode_request_free: mode_request_free,
          mode_synthetic_request: mode_synthetic_request,
          mode_page_replay: mode_page_replay,
          render_call_request_free: render_call_request_free,
          render_call_synthetic_request: render_call_synthetic_request,
          render_call_page_replay: render_call_page_replay,
          replay_forced: replay_forced,
          downgrades: downgrades,
          metrics_url: @metrics_url,
          timestamp: @timestamp
        }
      end

      def counter_delta(pre, post, name)
        sum_counter(post, name) - sum_counter(pre, name)
      end

      def sum_counter(parsed, name)
        entries = parsed[name]
        return 0 if entries.nil? || entries.empty?

        entries.values.sum.to_i
      end

      def labeled_delta(pre, post, name, label_match)
        get = lambda do |parsed|
          entries = parsed[name] || {}
          entries.select { |labels, _| label_match.all? { |k, v| labels[k] == v } }.values.sum.to_i
        end
        get.call(post) - get.call(pre)
      end

      def sum_all_labels_delta(pre, post, name)
        (sum_counter(post, name) - sum_counter(pre, name))
      end

      def write_report(report)
        out = File.join(@results_dir, "classifier-identity-free-feed-#{@timestamp}.json")
        File.write(out, JSON.pretty_generate(report))
      end

      def print_report(report)
        puts ""
        puts "══ classifier/identity_free_feed result ══"
        puts "  VUs:                         #{report[:vus]}"
        puts "  Render groups (total):       #{report[:render_requests]}"
        puts "  Render groups tier=none:     #{report[:tier_none]}"
        puts "  Render groups tier=user-keyed: #{report[:tier_user_keyed]}"
        puts "  Render groups mode=request_free: #{report[:mode_request_free]}"
        puts "  Render groups mode=synthetic_request: #{report[:mode_synthetic_request]}"
        puts "  Render groups mode=page_replay: #{report[:mode_page_replay]}"
        puts "  Render calls mode=request_free: #{report[:render_call_request_free]}"
        puts "  Render calls mode=synthetic_request: #{report[:render_call_synthetic_request]}"
        puts "  Render calls mode=page_replay: #{report[:render_call_page_replay]}"
        puts "  Replay-forced groups:        #{report[:replay_forced]}"
        puts "  Dedup savings:               #{report[:dedup_savings]}"
        puts "  Deliveries:                  #{report[:deliveries]}"
        puts "  Classification downgrades:   #{report[:downgrades]}"
        if report[:ratio]
          puts format("  Dedup ratio:                 %.4f  (floor: %.2f)", report[:ratio], DEDUP_RATIO_FLOOR)
        else
          puts "  Dedup ratio: n/a (no render groups observed)"
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

  exit Upkeep::Benchmark::IdentityFreeFeed.new(**opts).run
end
