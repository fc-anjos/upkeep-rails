#!/usr/bin/env ruby
# frozen_string_literal: true

# Apples-to-apples report for the shared `/feed` surface. Both sides use
# anonymous page renders, writes, and cable subscriptions so the benchmark
# exercises Upkeep's implicit anonymous-public subscription path.

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

def labelled_delta(before, after, metric)
  before_values = before.dig("relay", metric) || {}
  after_values = after.dig("relay", metric) || {}

  (before_values.keys | after_values.keys).each_with_object({}) do |key, values|
    values[key] = after_values.fetch(key, 0).to_i - before_values.fetch(key, 0).to_i
  end
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

def ratio(numerator, denominator)
  return if numerator.nil? || denominator.nil? || denominator.to_f.zero?

  numerator.to_f / denominator.to_f
end

upkeep_entries = load_jsonl(File.join(results_dir, "metrics-upkeep-#{timestamp}.jsonl"))
upkeep_k6 = load_json(File.join(results_dir, "render-dedup-identity-free-feed-upkeep.json"))
turbo_k6 = load_json(File.join(results_dir, "render-dedup-identity-free-feed-turbo.json"))

upkeep_before = metric_data(upkeep_entries, "before")
upkeep_after = metric_data(upkeep_entries, "after-render-dedup-identity-free-feed-compare-upkeep")
upkeep_reactivity = upkeep_after["upkeep_reactivity"] || {}
upkeep_graph = upkeep_reactivity["subscription_graphs"] || {}
upkeep_delivery = upkeep_reactivity["delivery"] || {}
upkeep_identity = upkeep_reactivity["subscription_identity"] || {}
upkeep_live_deoptimizations = upkeep_delivery["live_deoptimizations"] || {}

upkeep_deliveries = k6_metric(upkeep_k6, "deliveries_observed", "count")
relay_render_groups = counter_delta(upkeep_before, upkeep_after, "render_groups_total")
runtime_render_groups = upkeep_delivery["render_groups"].to_i
upkeep_render_groups = relay_render_groups.positive? ? relay_render_groups : runtime_render_groups
render_dedup_savings = counter_delta(upkeep_before, upkeep_after, "render_dedup_savings_total")
if render_dedup_savings.zero? && upkeep_deliveries && upkeep_render_groups.positive?
  render_dedup_savings = upkeep_deliveries.to_i - upkeep_render_groups
end
turbo_refresh_gets = k6_metric(turbo_k6, "refresh_gets", "count")
relay_metrics_available = relay_render_groups.positive?
delivery_bytes = relay_metrics_available ? counter_delta(upkeep_before, upkeep_after, "delivery_payload_bytes_total") : nil
client_frames_sent = relay_metrics_available ? counter_delta(upkeep_before, upkeep_after, "client_frames_sent_total") : nil
relay_note = relay_metrics_available ? "" : "\nRelay metrics were unavailable in this run, so the Upkeep render-group row uses the app-local delivery counters.\n"

report = {
  "timestamp" => timestamp,
  "vus" => ENV["BENCH_VUS"]&.to_i,
  "transport_note" => "The /feed render/update surface and subscription transport are anonymous; no login/session is used.",
  "upkeep" => {
    "writes" => k6_metric(upkeep_k6, "writes_issued", "count"),
    "deliveries" => upkeep_deliveries,
    "render_groups" => upkeep_render_groups,
    "dedup_ratio" => ratio(upkeep_deliveries, upkeep_render_groups),
    "render_dedup_savings" => render_dedup_savings,
    "byte_equality_proofs" => proof_proven_delta(upkeep_before, upkeep_after, "byte_equality"),
    "delivery_bytes" => delivery_bytes,
    "client_frames_sent" => client_frames_sent,
    "rtt_p95_ms" => k6_metric(upkeep_k6, "rtt", "p(95)"),
    "post_p95_ms" => k6_metric(upkeep_k6, "post_latency", "p(95)"),
    "page_render_p95_ms" => k6_metric(upkeep_k6, "page_render", "p(95)"),
    "setup_p95_ms" => k6_metric(upkeep_k6, "setup_total", "p(95)"),
    "suback_p95_ms" => k6_metric(upkeep_k6, "suback", "p(95)"),
    "render_groups_by_tier" => labelled_delta(upkeep_before, upkeep_after, "render_groups_by_tier"),
    "render_groups_by_mode" => labelled_delta(upkeep_before, upkeep_after, "render_groups_by_mode"),
    "reactivity" => {
      "subscriptions" => upkeep_graph["subscriptions"],
      "frames" => upkeep_graph["frames"],
      "dependencies" => upkeep_graph["dependencies"],
      "shared_stream_names" => upkeep_graph["shared_stream_names"],
      "relay_metrics_available" => relay_metrics_available,
      "planned_targets" => upkeep_delivery["planned_targets"],
      "represented_subscribers" => upkeep_delivery["represented_subscribers"],
      "runtime_render_groups" => upkeep_delivery["render_groups"],
      "runtime_render_count" => upkeep_delivery["render_count"],
      "live_deoptimizations" => upkeep_live_deoptimizations
    },
    "subscription_identity" => upkeep_identity
  },
  "turbo" => {
    "writes" => k6_metric(turbo_k6, "writes_issued", "count"),
    "refreshes_observed" => k6_metric(turbo_k6, "refreshes_observed", "count"),
    "refresh_gets" => turbo_refresh_gets,
    "refresh_get_p95_ms" => k6_metric(turbo_k6, "refresh_get_latency", "p(95)"),
    "rtt_p95_ms" => k6_metric(turbo_k6, "rtt", "p(95)"),
    "post_p95_ms" => k6_metric(turbo_k6, "post_latency", "p(95)"),
    "page_render_p95_ms" => k6_metric(turbo_k6, "page_render", "p(95)"),
    "setup_p95_ms" => k6_metric(turbo_k6, "setup_total", "p(95)"),
    "suback_p95_ms" => k6_metric(turbo_k6, "suback", "p(95)")
  }
}

json_path = File.join(results_dir, "identity-free-feed-compare-#{timestamp}.json")
md_path = File.join(results_dir, "identity-free-feed-compare-#{timestamp}.md")

File.write(json_path, JSON.pretty_generate(report))

upkeep = report.fetch("upkeep")
turbo = report.fetch("turbo")

File.write(md_path, <<~MARKDOWN)
  # Identity-Free Feed — Upkeep vs Turbo

  Timestamp: `#{timestamp}`
  VUs: #{report["vus"] || "(default)"}

  Note: `/feed` render, write, and subscription paths are identity-free.
  No login/session is used; Upkeep must classify the graph as anonymous
  public and allow the cable subscription without connection identity.
  #{relay_note}

  | Metric | Upkeep | Turbo |
  | --- | ---: | ---: |
  | Writes issued | #{fmt(upkeep["writes"])} | #{fmt(turbo["writes"])} |
  | Subscriber events observed | #{fmt(upkeep["deliveries"])} | #{fmt(turbo["refreshes_observed"])} |
  | Upkeep render groups | #{fmt(upkeep["render_groups"])} | n/a |
  | Upkeep delivery/render ratio | #{fmt(upkeep["dedup_ratio"])} | n/a |
  | Turbo refresh GETs | n/a | #{fmt(turbo["refresh_gets"])} |
  | Setup p95 ms | #{fmt(upkeep["setup_p95_ms"])} | #{fmt(turbo["setup_p95_ms"])} |
  | Page render p95 ms | #{fmt(upkeep["page_render_p95_ms"])} | #{fmt(turbo["page_render_p95_ms"])} |
  | Subscribe ack p95 ms | #{fmt(upkeep["suback_p95_ms"])} | #{fmt(turbo["suback_p95_ms"])} |
  | Write POST p95 ms | #{fmt(upkeep["post_p95_ms"])} | #{fmt(turbo["post_p95_ms"])} |
  | Update→settled p95 ms | #{fmt(upkeep["rtt_p95_ms"])} | #{fmt(turbo["rtt_p95_ms"])} |
  | Delivery bytes packed (Upkeep relay) | #{fmt(upkeep["delivery_bytes"])} | n/a |
  | Client frames sent (Upkeep relay) | #{fmt(upkeep["client_frames_sent"])} | n/a |

  ## Upkeep Dispatch Shape

  | Metric | Value |
  | --- | ---: |
  | Render dedup savings | #{fmt(upkeep["render_dedup_savings"])} |
  | Byte-equality proofs | #{fmt(upkeep["byte_equality_proofs"])} |
  | Runtime render groups | #{fmt(upkeep.dig("reactivity", "runtime_render_groups"))} |
  | Runtime render count | #{fmt(upkeep.dig("reactivity", "runtime_render_count"))} |
  | Planned targets | #{fmt(upkeep.dig("reactivity", "planned_targets"))} |
  | Represented subscribers | #{fmt(upkeep.dig("reactivity", "represented_subscribers"))} |
  | Live delivery deopts | `#{upkeep.dig("reactivity", "live_deoptimizations") || {}}` |
  | Render groups by tier | `#{upkeep["render_groups_by_tier"]}` |
  | Render groups by mode | `#{upkeep["render_groups_by_mode"]}` |
  | Subscription identity modes | `#{upkeep.dig("subscription_identity", "by_mode") || {}}` |
  | Anonymous deopts | `#{upkeep.dig("subscription_identity", "anonymous_deopts") || {}}` |
  | Stored subscriptions | #{fmt(upkeep.dig("reactivity", "subscriptions"))} |
  | Shared stream names | #{fmt(upkeep.dig("reactivity", "shared_stream_names"))} |

  ## Reading the comparison

  This is the high-sharing shape where Upkeep should have room to close
  or beat Turbo: one shared, identity-free write fans out to many
  subscribers. Turbo's standard refresh path turns each subscriber event
  into a page GET. Upkeep should collapse the render work and ship
  subscriber deliveries from the registered reactive graph.
MARKDOWN

puts "Identity-free feed compare report: #{md_path}"
