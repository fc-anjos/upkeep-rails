#!/usr/bin/env ruby
# frozen_string_literal: true

# Apples-to-apples Upkeep vs Turbo report for the singular FeaturedItems
# resource. Run by `benchmark/bin/run` after both apps' k6 scripts have
# finished. Reads the dispatch /metrics snapshots and the k6 summaries to
# show byte-equality proof verdicts (Upkeep) beside refresh-driven
# delivery counts (Turbo), plus wire-bytes and RSS deltas.

require "json"
require "time"

results_dir = ARGV[0] || File.expand_path("results", __dir__)
timestamp = ARGV[1] || Time.now.strftime("%Y%m%d%H%M%S")

def load_jsonl(path)
  return [] unless File.exist?(path)

  File.readlines(path).filter_map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end
end

def load_json(path)
  return {} unless File.exist?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError
  {}
end

def metric_data(entries, label)
  entries.find { |entry| entry["label"] == label }&.dig("data") || {}
end

def counter_delta(before, after, *path)
  after.dig("relay", "counters", *path).to_i - before.dig("relay", "counters", *path).to_i
end

def proof_proven_delta(before, after, reason)
  after.dig("relay", "proof_proven", "by_reason", reason).to_i -
    before.dig("relay", "proof_proven", "by_reason", reason).to_i
end

def k6_metric(data, metric, key)
  data.dig("metrics", metric, "values", key)
end

def fmt(value)
  case value
  when nil then "-"
  when Float then format("%.2f", value)
  else value.to_s
  end
end

upkeep_entries = load_jsonl(File.join(results_dir, "metrics-upkeep-#{timestamp}.jsonl"))
upkeep_k6 = load_json(File.join(results_dir, "render-dedup-mixed-region-feed-ivar.json"))
turbo_k6 = load_json(File.join(results_dir, "render-dedup-mixed-region-feed-ivar-turbo.json"))

upkeep_before = metric_data(upkeep_entries, "before")
upkeep_after = metric_data(upkeep_entries, "after-featured-item-upkeep")

report = {
  "timestamp" => timestamp,
  "vus" => ENV["BENCH_VUS"]&.to_i,
  "upkeep" => {
    "byte_equality_proofs" => proof_proven_delta(upkeep_before, upkeep_after, "byte_equality"),
    "render_groups" => counter_delta(upkeep_before, upkeep_after, "render_groups_total"),
    "render_dedup_savings" => counter_delta(upkeep_before, upkeep_after, "render_dedup_savings_total"),
    "delivery_bytes" => counter_delta(upkeep_before, upkeep_after, "delivery_payload_bytes_total"),
    "client_frames_sent" => counter_delta(upkeep_before, upkeep_after, "client_frames_sent_total"),
    "rtt_p95_ms" => k6_metric(upkeep_k6, "rtt", "p(95)"),
    "writes" => k6_metric(upkeep_k6, "writes_issued", "count"),
    "deliveries" => k6_metric(upkeep_k6, "deliveries_observed", "count")
  },
  "turbo" => {
    "refreshes_observed" => k6_metric(turbo_k6, "refreshes_observed", "count"),
    "refresh_gets" => k6_metric(turbo_k6, "refresh_gets", "count"),
    "refresh_get_p95_ms" => k6_metric(turbo_k6, "refresh_get_latency", "p(95)"),
    "rtt_p95_ms" => k6_metric(turbo_k6, "rtt", "p(95)"),
    "writes" => k6_metric(turbo_k6, "writes_issued", "count")
  }
}

json_path = File.join(results_dir, "featured-item-compare-#{timestamp}.json")
md_path = File.join(results_dir, "featured-item-compare-#{timestamp}.md")

File.write(json_path, JSON.pretty_generate(report))

upkeep = report["upkeep"]
turbo = report["turbo"]

File.write(md_path, <<~MARKDOWN)
  # Featured Item — Upkeep vs Turbo

  Timestamp: `#{timestamp}`
  VUs: #{report["vus"] || "(default)"}

  | Metric | Upkeep | Turbo |
  | --- | ---: | ---: |
  | Writes issued | #{fmt(upkeep["writes"])} | #{fmt(turbo["writes"])} |
  | Subscriber events observed | #{fmt(upkeep["deliveries"])} | #{fmt(turbo["refreshes_observed"])} |
  | Byte-equality proven verdicts | #{fmt(upkeep["byte_equality_proofs"])} | n/a |
  | Render groups | #{fmt(upkeep["render_groups"])} | n/a |
  | Refresh GETs (page re-fetches) | n/a | #{fmt(turbo["refresh_gets"])} |
  | Delivery bytes packed (relay → client) | #{fmt(upkeep["delivery_bytes"])} | n/a |
  | Refresh GET p95 ms | n/a | #{fmt(turbo["refresh_get_p95_ms"])} |
  | Update→delivery RTT p95 ms | #{fmt(upkeep["rtt_p95_ms"])} | #{fmt(turbo["rtt_p95_ms"])} |

  ## Reading the comparison

  Upkeep's relay proves byte-equality at the proof gate and ships a
  compact ops patch — no re-render, no full page fetch. Turbo's
  `after_update_commit` callback broadcasts a refresh ping; every
  subscriber re-fetches the page and the client diffs the response
  into the DOM. The `Refresh GETs` column is the work Turbo's
  subscribers do that Upkeep avoids; the `Egress bytes` column is
  what Upkeep ships in place of those refetches.
MARKDOWN

puts "Featured item compare report: #{md_path}"
