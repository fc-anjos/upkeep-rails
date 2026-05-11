# frozen_string_literal: true

# Ivar-shaped mixed-region render-dedup benchmark.
#
# Drives `benchmark/k6/render_dedup/mixed_region_feed_ivar.js`. Mirrors
# the structure of the sibling `mixed_region_feed` runner but:
#
# - The benchmark app's `/featured_item` page renders a partial whose
#   dynamic sources are controller ivars (`@featured_item.title`,
#   `@featured_item.body`).
# - At subscribe time, `SlotStateCapture` resolves each ivar via
#   `view_assigns` threaded through `FragmentRegistrationMetadata::Builder`,
#   populating `fragment_slot_states["value"]` for the ivar-bound slots.
# - One writer updates the same FeedItem row; every subscriber should
#   receive a byte-equality-proven patch (no synthetic-request render)
#   because the proof gate now sees a populated binding.
#
# Pass criteria mirror the parent `mixed_region_feed` set: zero render
# Render call errors, zero classification downgrades, and at least one proof
# activity signal — either render-path region outcomes (the older
# region-grouping path) or `:byte_equality` proven verdicts (the
# direct-push proof path that ships ops without rendering). The
# parent runner now exposes `byte_equality_proofs` in the report so
# subclasses inherit proof-aware acceptance without overriding
# `status_for`.

require_relative "mixed_region_feed"

module Upkeep
  module Benchmark
    class MixedRegionFeedIvar < MixedRegionFeed
      private

      def workload_script
        File.expand_path("../../k6/render_dedup/mixed_region_feed_ivar.js", __dir__)
      end

      # In addition to the parent's "any proof activity" check, this
      # workload's defining property is that every invalidation must
      # prove byte-equality: the page renders a single ivar-bound
      # fragment whose only dynamic source is `@featured_item.title`,
      # so any non-proven verdict is a regression in the ivar code
      # path. Keep the parent assertions, then
      # add a strict `byte_equality_proofs > 0` check on top.
      def status_for(report, dispatch_metrics, workload_status)
        base_status = super
        return base_status unless base_status.zero?

        if report[:byte_equality_proofs].zero?
          warn("[mixed_region_feed_ivar] byte_equality proof verdicts = 0 — ivar proof path did not fire")
          return 2
        end

        0
      end

      def write_report(report)
        out = File.join(results_dir, "render-dedup-mixed-region-feed-ivar-#{timestamp}.json")
        File.write(out, JSON.pretty_generate(report))
      end

      def print_report(report)
        super
        puts "  (workload variant: ivar; byte-equality proof verdicts are required)"
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

  exit Upkeep::Benchmark::MixedRegionFeedIvar.new(**opts).run
end
