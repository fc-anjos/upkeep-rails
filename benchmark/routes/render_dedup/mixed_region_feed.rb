# frozen_string_literal: true

# Mixed-region render-dedup benchmark.
#
# Drives `benchmark/k6/render_dedup/mixed_region_feed.js` with many
# authenticated subscribers on `/mixed_feed`. The route runner samples
# relay Prometheus counters and app benchmark counters around the run
# and records whether region planning saw stable direct-push regions
# beside subscriber-specific replay/fallback regions.

require "json"
require "fileutils"
require "net/http"
require "optparse"
require "uri"
require_relative "../../shared/prom_parse"

module Upkeep
  module Benchmark
    class MixedRegionFeed
      REGION_DIRECT_PUSH = "region_direct_push"
      REGION_REPLAY = "region_replay"

      def initialize(base_url:, ws_url:, metrics_url:, vus:, results_dir:, timestamp:)
        @base_url = base_url
        @ws_url = ws_url
        @metrics_url = metrics_url
        @vus = vus
        @results_dir = results_dir
        @timestamp = timestamp
      end

      def run
        pre_dispatch = scrape_dispatch_metrics
        pre_app = scrape_app_metrics
        started_at_ms = wall_time_ms
        workload_status = run_workload!
        finished_at_ms = wall_time_ms
        post_dispatch = scrape_dispatch_metrics
        post_app = scrape_app_metrics

        report = build_report(pre_dispatch, post_dispatch, pre_app, post_app, started_at_ms, finished_at_ms)
        write_report(report)
        print_report(report)

        status_for(report, post_dispatch, workload_status)
      end

      private

      attr_reader :results_dir, :timestamp

      def status_for(report, dispatch_metrics, workload_status)
        if dispatch_metrics.empty?
          warn("[mixed_region_feed] dispatch /metrics scrape returned no data — check #{@metrics_url}")
          1
        elsif workload_status != 0
          warn("[mixed_region_feed] workload exited non-zero (#{workload_status})")
          1
        elsif report[:render_call_errors].positive?
          warn("[mixed_region_feed] render_call_errors_total delta = #{report[:render_call_errors]} (must be 0)")
          2
        elsif !report[:traffic_observed]
          warn("[mixed_region_feed] no dispatch render or delivery traffic observed")
          2
        elsif !proof_activity_observed?(report)
          warn("[mixed_region_feed] no proof activity observed " \
               "(byte_equality_proofs=0 AND region_direct_push=0 AND region_replay=0)")
          2
        elsif report[:classification_downgrades].positive?
          warn("[mixed_region_feed] classification_downgrades_total delta = #{report[:classification_downgrades]} (must be 0)")
          2
        else
          0
        end
      end

      # Either the render path produced region outcomes, or the proof
      # gate fired and delivered patches without rendering. Both are
      # valid success signals for a mixed-region workload, and a
      # workload that proves every invalidation will report zero
      # region telemetry (no render = no region_outcomes), so requiring
      # render-path metrics specifically would fail the gate on a
      # working all-proven configuration.
      def proof_activity_observed?(report)
        report[:byte_equality_proofs].to_i.positive? ||
          report[:region_outcomes].fetch(REGION_DIRECT_PUSH, 0).positive? ||
          report[:region_outcomes].fetch(REGION_REPLAY, 0).positive?
      end

      def scrape_dispatch_metrics
        uri = URI(@metrics_url)
        Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 2) do |http|
          response = http.get(uri.path.empty? ? "/metrics" : uri.path)
          return PromParse.parse(response.body) if response.is_a?(Net::HTTPSuccess)
        end
        {}
      rescue StandardError => e
        warn("[mixed_region_feed] dispatch metrics scrape failed: #{e.class}: #{e.message}")
        {}
      end

      def scrape_app_metrics
        uri = URI.join(@base_url, "/bench/metrics")
        Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 2) do |http|
          response = http.get(uri.request_uri)
          return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
        end
        {}
      rescue StandardError => e
        warn("[mixed_region_feed] app metrics scrape failed: #{e.class}: #{e.message}")
        {}
      end

      def run_workload!
        env = {
          "BASE_URL" => @base_url,
          "WS_URL" => @ws_url,
          "BENCH_VUS" => @vus.to_s,
          "NUM_USERS" => ENV.fetch("NUM_USERS", "200")
        }
        cmd = [ "k6", "run", workload_script ]
        log_file = File.join(results_dir, "render-dedup-mixed-region-feed-k6-#{timestamp}.log")
        FileUtils.mkdir_p(results_dir)

        pid = Process.spawn(env, *cmd, out: log_file, err: [ :child, :out ])
        _, status = Process.waitpid2(pid)
        return 0 if status.success?

        warn("[mixed_region_feed] k6 exited non-zero (#{status.exitstatus}); see #{log_file}")
        status.exitstatus || 1
      end

      def workload_script
        File.expand_path("../../k6/render_dedup/mixed_region_feed.js", __dir__)
      end

      def build_report(pre_dispatch, post_dispatch, pre_app, post_app, started_at_ms, finished_at_ms)
        event_report = app_event_report(started_at_ms, finished_at_ms)
        region_outcomes = region_outcome_delta(pre_app, post_app)
        region_outcomes = event_report[:region_outcomes] if region_outcomes.empty?

        render_groups = counter_delta(pre_dispatch, post_dispatch, "upkeep_relay_render_groups_total")
        dedup_savings = counter_delta(pre_dispatch, post_dispatch, "upkeep_relay_render_dedup_savings_total")
        bytes_enqueued = counter_delta(pre_dispatch, post_dispatch, "upkeep_relay_egress_frame_bytes_enqueued_total")
        byte_equality_proofs = labelled_delta(
          pre_dispatch, post_dispatch, "upkeep_relay_proof_proven_total", "reason"
        ).fetch("byte_equality", 0)

        {
          vus: @vus,
          render_groups: render_groups,
          deliveries: render_groups + dedup_savings,
          dedup_savings: dedup_savings,
          dedup_ratio: dedup_ratio(render_groups, dedup_savings),
          replay_forced_groups: counter_delta(pre_dispatch, post_dispatch, "upkeep_relay_replay_forced_groups_total"),
          classification_downgrades: counter_delta(pre_dispatch, post_dispatch, "upkeep_relay_classification_downgrades_total"),
          render_call_errors: counter_delta(pre_dispatch, post_dispatch, "upkeep_relay_render_call_errors_total"),
          bytes_enqueued: bytes_enqueued,
          render_groups_by_mode: labelled_delta(pre_dispatch, post_dispatch, "upkeep_relay_render_groups_by_mode", "mode"),
          render_calls_by_mode: labelled_delta(pre_dispatch, post_dispatch, "upkeep_relay_render_calls_total", "mode"),
          app_renders: app_counter_delta(pre_app, post_app, "renders"),
          app_render_requests: event_report[:render_requests],
          app_page_replays: event_report[:page_replays],
          region_outcomes: region_outcomes,
          byte_equality_proofs: byte_equality_proofs,
          traffic_observed: render_groups.positive? || bytes_enqueued.positive? || byte_equality_proofs.positive?,
          metrics_url: @metrics_url,
          timestamp: timestamp
        }
      end

      def app_event_report(started_at_ms, finished_at_ms)
        events = app_events_between(started_at_ms, finished_at_ms)
        region_outcomes = events
          .select { |event| event["event"] == "upkeep_render_region_outcome" }
          .each_with_object(Hash.new(0)) { |event, counts| counts[event["outcome"].to_s] += 1 }

        {
          render_requests: events.count { |event| event["event"] == "upkeep_render_request" },
          page_replays: events.count { |event| event["event"] == "upkeep_render_page_replay" },
          region_outcomes: region_outcomes.to_h
        }
      end

      def app_events_between(started_at_ms, finished_at_ms)
        app_log_paths.flat_map do |path|
          File.readlines(path, chomp: true).filter_map do |line|
            entry = JSON.parse(line)
            wall = entry["wall_time_ms"].to_f
            entry if wall >= started_at_ms && wall <= finished_at_ms
          rescue JSON::ParserError
            nil
          end
        end
      end

      def app_log_paths
        Dir.glob(File.join(results_dir, "server-upkeep-*.jsonl"))
      end

      def counter_delta(pre, post, name)
        sum_counter(post, name) - sum_counter(pre, name)
      end

      def sum_counter(parsed, name)
        entries = parsed[name] || {}
        entries.values.sum.to_i
      end

      def labelled_delta(pre, post, name, label_key)
        pre_entries = pre[name] || {}
        post_entries = post[name] || {}
        keys = (pre_entries.keys + post_entries.keys).uniq
        keys.each_with_object({}) do |labels, out|
          label = labels[label_key]
          next unless label
          delta = post_entries[labels].to_i - pre_entries[labels].to_i
          out[label] = delta if delta.positive?
        end
      end

      def app_counter_delta(pre_app, post_app, counter)
        post_app.dig("counters", counter).to_i - pre_app.dig("counters", counter).to_i
      end

      def region_outcome_delta(pre_app, post_app)
        pre = pre_app.fetch("region_outcomes", {})
        post = post_app.fetch("region_outcomes", {})
        (pre.keys + post.keys).uniq.each_with_object({}) do |key, out|
          delta = post[key].to_i - pre[key].to_i
          out[key] = delta if delta.positive?
        end
      end

      def dedup_ratio(render_groups, dedup_savings)
        deliveries = render_groups + dedup_savings
        return 0.0 if deliveries.zero?

        (dedup_savings.to_f / deliveries).round(4)
      end

      def write_report(report)
        out = File.join(results_dir, "render-dedup-mixed-region-feed-#{timestamp}.json")
        File.write(out, JSON.pretty_generate(report))
      end

      def print_report(report)
        puts ""
        puts "══ render_dedup/mixed_region_feed result ══"
        puts "  VUs:                     #{report[:vus]}"
        puts "  Byte-equality proofs:    #{report[:byte_equality_proofs]}"
        puts "  Render groups:           #{report[:render_groups]}"
        puts "  Deliveries:              #{report[:deliveries]}"
        puts "  Dedup savings:           #{report[:dedup_savings]}"
        puts format("  Dedup ratio:             %.4f", report[:dedup_ratio])
        puts "  Replay-forced groups:    #{report[:replay_forced_groups]}"
        puts "  Classification downgrades: #{report[:classification_downgrades]}"
        puts "  Render call errors:       #{report[:render_call_errors]}"
        puts "  Bytes enqueued:          #{report[:bytes_enqueued]}"
        puts "  App renders:             #{report[:app_renders]}"
        puts "  App render requests:     #{report[:app_render_requests]}"
        puts "  App page replays:        #{report[:app_page_replays]}"
        puts "  Render groups by mode:   #{report[:render_groups_by_mode].inspect}"
        puts "  Render calls by mode:       #{report[:render_calls_by_mode].inspect}"
        puts "  Region outcomes:         #{report[:region_outcomes].inspect}"
      end

      def wall_time_ms
        (Time.now.to_f * 1000).round(3)
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

  exit Upkeep::Benchmark::MixedRegionFeed.new(**opts).run
end
