#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

module Upkeep
  module Benchmark
    class MemoryCeilingTopologySweep
      TOPOLOGIES = [
        { workers: 1, threads: 10 },
        { workers: 2, threads: 5 },
        { workers: 4, threads: 5 }
      ].freeze

      def initialize(bench_dir:, results_dir:, timestamp:, tier:, vus:, writes_per_vu:, rss_sample_interval:)
        @bench_dir = bench_dir
        @results_dir = results_dir
        @timestamp = timestamp
        @tier = tier
        @vus = vus
        @writes_per_vu = writes_per_vu
        @rss_sample_interval = rss_sample_interval
      end

      def run
        runs = TOPOLOGIES.each_with_index.map do |topology, index|
          run_topology(topology, index)
        end

        write_report(runs)
        runs.all? { |run| run.fetch("status").zero? } ? 0 : 1
      end

      private

      def run_topology(topology, index)
        child_timestamp = child_timestamp(index)
        puts "── Memory ceiling topology workers=#{topology.fetch(:workers)} threads=#{topology.fetch(:threads)} ──"

        env = ENV.to_h.merge(
          "BENCH" => "1",
          "BENCH_FAMILY" => "memory_ceiling",
          "BENCH_WORKLOAD" => "shared_feed_churn",
          "BENCH_TIER" => @tier,
          "BENCH_VUS" => @vus.to_s,
          "WRITES_PER_VU" => @writes_per_vu.to_s,
          "RSS_SAMPLE_INTERVAL" => @rss_sample_interval.to_s,
          "PUMA_WORKERS" => topology.fetch(:workers).to_s,
          "PUMA_THREADS" => topology.fetch(:threads).to_s,
          "BENCH_TIMESTAMP" => child_timestamp
        )

        system(env, File.join(@bench_dir, "bin/run"))
        status = $?.exitstatus || 1

        report = load_child_report(child_timestamp)
        summary_for(topology, child_timestamp, status, report)
      end

      def child_timestamp(index)
        (Time.now + index).strftime("%Y%m%d%H%M%S")
      end

      def load_child_report(child_timestamp)
        path = File.join(@results_dir, "memory-ceiling-shared-feed-churn-#{child_timestamp}.json")
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      def summary_for(topology, child_timestamp, status, report)
        {
          "timestamp" => child_timestamp,
          "status" => status,
          "puma_workers" => topology.fetch(:workers),
          "puma_threads" => topology.fetch(:threads),
          "peak_app_rss_mb" => {
            "upkeep" => report.dig("upkeep", "rss", "peak_app_mb"),
            "turbo" => report.dig("turbo", "rss", "peak_app_mb")
          },
          "peak_combined_rss_mb" => report.dig("upkeep", "rss", "peak_combined_mb"),
          "process_rss" => report.dig("upkeep", "process_rss") || {},
          "final_heap_allocated_pages" => report.dig("upkeep", "memory_snapshot", "heap_allocated_pages"),
          "final_action_cable_counts" => report.dig("upkeep", "memory_snapshot", "action_cable_counts") || {},
          "post_p95_ms" => {
            "upkeep" => report.dig("upkeep", "p95_post_ms"),
            "turbo" => report.dig("turbo", "p95_post_ms")
          }
        }
      end

      def write_report(runs)
        json_path = File.join(@results_dir, "memory-ceiling-topology-sweep-#{@timestamp}.json")
        md_path = File.join(@results_dir, "memory-ceiling-topology-sweep-#{@timestamp}.md")

        File.write(json_path, JSON.pretty_generate("timestamp" => @timestamp, "runs" => runs))
        File.write(md_path, markdown_for(runs))

        puts ""
        puts "Memory ceiling topology sweep report: #{md_path}"
      end

      def markdown_for(runs)
        rows = runs.map do |run|
          worker_summary = run.dig("process_rss", "roles", "upkeep_puma_worker") || {}
          master_summary = run.dig("process_rss", "roles", "upkeep_puma_master") || {}
          action_cable_counts = run.fetch("final_action_cable_counts")

          "| #{run.fetch("timestamp")} | #{run.fetch("puma_workers")} | #{run.fetch("puma_threads")} | #{run.fetch("status")} | #{fmt(run.dig("peak_app_rss_mb", "upkeep"))} | #{fmt(run.dig("peak_app_rss_mb", "turbo"))} | #{fmt(worker_summary["peak_mb"])} | #{fmt(master_summary["peak_mb"])} | #{fmt(run["peak_combined_rss_mb"])} | #{fmt(run["final_heap_allocated_pages"])} | #{fmt(action_cable_counts["ActionCable::Connection::Base"])} |"
        end.join("\n")

        <<~MARKDOWN
          # Memory Ceiling Topology Sweep

          Timestamp: `#{@timestamp}`

          | Timestamp | Workers | Threads | Exit | Upkeep app peak MB | Turbo app peak MB | Upkeep worker peak MB | Upkeep master peak MB | Upkeep combined peak MB | Final heap pages | Final AC connections |
          | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
          #{rows}
        MARKDOWN
      end

      def fmt(value)
        value.nil? ? "—" : value.to_s
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {
    bench_dir: File.expand_path("../..", __dir__),
    results_dir: ENV["BENCH_RESULTS_DIR"],
    timestamp: ENV["BENCH_TIMESTAMP"] || Time.now.strftime("%Y%m%d%H%M%S"),
    tier: ENV["BENCH_TIER"] || "smoke",
    vus: Integer(ENV["BENCH_VUS"] || "50"),
    writes_per_vu: Integer(ENV["WRITES_PER_VU"] || "3"),
    rss_sample_interval: Integer(ENV["RSS_SAMPLE_INTERVAL"] || "5")
  }

  OptionParser.new do |o|
    o.on("--bench-dir=DIR") { |value| opts[:bench_dir] = value }
    o.on("--results-dir=DIR") { |value| opts[:results_dir] = value }
    o.on("--timestamp=TIMESTAMP") { |value| opts[:timestamp] = value }
    o.on("--tier=TIER") { |value| opts[:tier] = value }
    o.on("--vus=N", Integer) { |value| opts[:vus] = value }
    o.on("--writes-per-vu=N", Integer) { |value| opts[:writes_per_vu] = value }
    o.on("--rss-sample-interval=N", Integer) { |value| opts[:rss_sample_interval] = value }
  end.parse!
  opts[:results_dir] ||= File.join(opts.fetch(:bench_dir), "results")

  exit Upkeep::Benchmark::MemoryCeilingTopologySweep.new(**opts).run
end
