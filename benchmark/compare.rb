#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"

results_dir = ARGV[0] || File.expand_path("results", __dir__)
timestamp = ARGV[1] || Time.now.strftime("%Y%m%d%H%M%S")

def load_k6(path)
  return nil unless File.exist?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  warn "Warning: Could not parse #{path}: #{e.message}"
  nil
end

def extract_trend(data, metric_name)
  return {} unless data

  metric = data.dig("metrics", metric_name)
  return {} unless metric && metric["values"]

  values = metric["values"]
  {
    "p50" => values["p(50)"]&.round(2),
    "p95" => values["p(95)"]&.round(2),
    "p99" => values["p(99)"]&.round(2),
    "avg" => values["avg"]&.round(2),
    "min" => values["min"]&.round(2),
    "max" => values["max"]&.round(2)
  }
end

def extract_counter(data, metric_name)
  return 0 unless data

  data.dig("metrics", metric_name, "values", "count") || 0
end

def summarize(values)
  return {} if values.empty?

  sorted = values.sort
  percentile = lambda do |ratio|
    index = (ratio * (sorted.length - 1)).round
    sorted[index]
  end

  {
    "p50" => percentile.call(0.50).round(3),
    "p95" => percentile.call(0.95).round(3),
    "p99" => percentile.call(0.99).round(3),
    "avg" => (sorted.sum / sorted.length.to_f).round(3),
    "min" => sorted.first.round(3),
    "max" => sorted.last.round(3)
  }
end

def load_server_events(results_dir, app_name)
  files = Dir.glob(File.join(results_dir, "server-#{app_name}-*.jsonl"))
  return [] if files.empty?

  File.readlines(files.last).filter_map { |line| begin
                                            JSON.parse(line)
                                          rescue
                                            nil
                                          end }
end

def load_server_metrics(events)
  render_event_names = %w[render_template render_partial]
  render_events = events.select { |event| render_event_names.include?(event["event"]) }
  memory_events = events.select { |event| event["event"] == "memory_sample" }
  transmit_events = events.select { |event| event["event"] == "transmit" }

  {
    "avg_render_ms" => render_events.empty? ? nil : (render_events.sum { |event| event["duration_ms"] || 0 } / render_events.size.to_f).round(3),
    "render_count" => render_events.size,
    "avg_payload_bytes" => transmit_events.empty? ? nil : (transmit_events.sum { |event| event["payload_bytes"] || 0 } / transmit_events.size.to_f).round(0),
    "peak_rss_mb" => memory_events.empty? ? nil : memory_events.max_by { |event| event["memory_rss_mb"] || 0 }["memory_rss_mb"]
  }
end

def load_polled_metrics(results_dir, app_name, timestamp)
  file = File.join(results_dir, "metrics-#{app_name}-#{timestamp}.jsonl")
  return [] unless File.exist?(file)

  File.readlines(file).filter_map { |line| begin
                                      JSON.parse(line)
                                    rescue
                                      nil
                                    end }
end

def polled_summary(entries)
  return {} if entries.empty?

  before = entries.find { |entry| entry["label"] == "before" }&.dig("data") || {}
  final = entries.find { |entry| entry["label"] == "final" }&.dig("data") || {}
  relay = final["relay"] || {}
  reactivity = final["upkeep_reactivity"] || {}
  graph = reactivity["subscription_graphs"] || {}
  ambient = graph["ambient_replay_inputs"] || {}
  refused = reactivity["refused_boundaries"] || {}
  delivery = reactivity["delivery"] || {}
  live_deopts = delivery["live_deoptimizations"] || {}

  effective_transmits = final.dig("counters", "transmits_total") ||
                        final.dig("counters", "transmits")

  {
    "rss_before_mb" => before.dig("rss_mb"),
    "rss_final_mb" => final.dig("rss_mb"),
    "gc_count" => final.dig("gc", "gc_count"),
    "major_gc_count" => final.dig("gc", "major_gc_count"),
    "heap_live_slots" => final.dig("gc", "heap_live_slots"),
    "renders" => final.dig("counters", "renders"),
    "invalidations" => final.dig("counters", "invalidations"),
    "broadcasts" => final.dig("counters", "broadcasts"),
    "transmits" => effective_transmits,
    "relay_client_frames" => relay.dig("counters", "client_frames_sent_total"),
    "relay_client_frames_dropped_no_connection" =>
      relay.dig("counters", "client_frames_dropped_no_connection_total"),
    "relay_render_groups_total" => relay.dig("counters", "render_groups_total"),
    "relay_render_dedup_savings_total" => relay.dig("counters", "render_dedup_savings_total"),
    "relay_dedup_ratio" => relay.dig("counters", "dedup_ratio"),
    "relay_render_mode_request_free" => relay.dig("render_groups_by_mode", "request_free"),
    "relay_render_mode_synthetic_request" => relay.dig("render_groups_by_mode", "synthetic_request"),
    "relay_render_mode_page_replay" => relay.dig("render_groups_by_mode", "page_replay"),
    "relay_proof_fallbacks" => relay.dig("proof_fallback", "by_reason"),
    "relay_runtime_contradictions" => relay.dig("runtime_contradiction", "by_mode"),
    "reactivity_subscriptions" => graph["subscriptions"],
    "reactivity_frames" => graph["frames"],
    "reactivity_dependencies" => graph["dependencies"],
    "reactivity_replay_recipes" => graph["replay_recipes"],
    "reactivity_replay_recipe_bytes_total" => graph["replay_recipe_bytes_total"],
    "reactivity_replay_recipe_bytes_max" => graph["replay_recipe_bytes_max"],
    "reactivity_ambient_replay_inputs" => ambient["total"],
    "reactivity_ambient_replay_inputs_by_source" => ambient["by_source"],
    "reactivity_dependency_sources" => graph["dependency_sources"],
    "reactivity_refused_boundaries" => refused["total"],
    "reactivity_refused_boundaries_by_reason" => refused["by_reason"],
    "reactivity_live_deoptimizations" => live_deopts["total"],
    "reactivity_live_deoptimizations_by_reason" => live_deopts["by_reason"],
    "reactivity_render_groups" => delivery["render_groups"],
    "reactivity_render_count" => delivery["render_count"],
    "subscription_count" => final.dig("subscription_count")
  }
end

def label_timestamp(entries, label)
  entry = entries.find { |candidate| candidate["label"] == label }
  return nil unless entry

  timestamp = entry.dig("data", "timestamp")
  # An `unreachable: true` entry carries `data: null` — the metrics
  # endpoint timed out post-scenario but the run continued. Treat as
  # missing so windowed event collectors fall back to the prior
  # checkpoint instead of crashing on `Time.parse(nil)`.
  return nil unless timestamp

  Time.parse(timestamp).to_f * 1000
rescue ArgumentError
  nil
end

def window_events(events, label_entries, end_label:, start_labels:)
  finish = label_timestamp(label_entries, end_label)
  return [] unless finish

  start = start_labels.filter_map { |label| label_timestamp(label_entries, label) }.compact.max || 0

  events.select do |event|
    wall_time = event["wall_time_ms"]
    wall_time && wall_time >= start && wall_time <= finish
  end
end

def event_stats(events, event_name, filters = {})
  durations = events.filter_map do |event|
    next unless event["event"] == event_name
    next unless filters.all? { |key, value| event[key.to_s] == value }

    event["duration_ms"]
  end

  summarize(durations)
end

def dominant_phase(phases)
  phases.compact.max_by { |_name, value| value }
end

def fmt(value)
  return "—" if value.nil?

  value.is_a?(Float) ? value.round(2).to_s : value.to_s
end

scenarios = {
  "chat-warm-upkeep" => load_k6(File.join(results_dir, "matrix-chat-warm-upkeep.json")),
  "chat-warm-turbo" => load_k6(File.join(results_dir, "matrix-chat-warm-turbo.json")),
  "chat-cold-upkeep" => load_k6(File.join(results_dir, "matrix-chat-cold-upkeep.json")),
  "chat-cold-turbo" => load_k6(File.join(results_dir, "matrix-chat-cold-turbo.json")),
  "board-upkeep" => load_k6(File.join(results_dir, "matrix-board-upkeep.json")),
  "board-turbo" => load_k6(File.join(results_dir, "matrix-board-turbo.json"))
}

server_events = {
  "upkeep" => load_server_events(results_dir, "upkeep"),
  "turbo" => load_server_events(results_dir, "turbo")
}

server = {
  "upkeep" => load_server_metrics(server_events["upkeep"]),
  "turbo" => load_server_metrics(server_events["turbo"])
}

polled_entries = {
  "upkeep" => load_polled_metrics(results_dir, "upkeep", timestamp),
  "turbo" => load_polled_metrics(results_dir, "turbo", timestamp)
}

polled = {
  "upkeep" => polled_summary(polled_entries["upkeep"]),
  "turbo" => polled_summary(polled_entries["turbo"])
}

cold_phase_windows = {
  "upkeep" => window_events(
    server_events["upkeep"],
    polled_entries["upkeep"],
    end_label: "after-chat-cold",
    start_labels: [ "after-chat-warm", "before" ]
  ),
  "turbo" => window_events(
    server_events["turbo"],
    polled_entries["turbo"],
    end_label: "after-chat-cold",
    start_labels: [ "after-chat-warm", "before" ]
  )
}

cold_server_phases = {
  "upkeep" => {
    "sessions#create" => event_stats(cold_phase_windows["upkeep"], "bench_request", phase: "sessions#create")["p95"],
    "rooms#show" => event_stats(cold_phase_windows["upkeep"], "bench_request", phase: "rooms#show")["p95"],
    "cable request" => event_stats(cold_phase_windows["upkeep"], "bench_cable_request")["p95"],
    "cable open" => event_stats(cold_phase_windows["upkeep"], "bench_cable_open")["p95"],
    "cable connect" => event_stats(cold_phase_windows["upkeep"], "bench_cable_connect")["p95"],
    "subscription registration" => event_stats(cold_phase_windows["upkeep"], "bench_subscription_registration")["p95"],
    "subscription confirmation" => event_stats(cold_phase_windows["upkeep"], "bench_subscription_confirmation")["p95"]
  },
  "turbo" => {
    "sessions#create" => event_stats(cold_phase_windows["turbo"], "bench_request", phase: "sessions#create")["p95"],
    "rooms#show" => event_stats(cold_phase_windows["turbo"], "bench_request", phase: "rooms#show")["p95"],
    "cable request" => event_stats(cold_phase_windows["turbo"], "bench_cable_request")["p95"],
    "cable open" => event_stats(cold_phase_windows["turbo"], "bench_cable_open")["p95"],
    "cable connect" => event_stats(cold_phase_windows["turbo"], "bench_cable_connect")["p95"],
    "subscription registration" => event_stats(cold_phase_windows["turbo"], "bench_subscription_registration")["p95"],
    "subscription confirmation" => event_stats(cold_phase_windows["turbo"], "bench_subscription_confirmation")["p95"]
  }
}

cold_client_phases = {
  "upkeep" => {
    "login_http" => extract_trend(scenarios["chat-cold-upkeep"], "login_latency")["p95"],
    "page_request" => extract_trend(scenarios["chat-cold-upkeep"], "page_render")["p95"],
    "ws_connecting" => extract_trend(scenarios["chat-cold-upkeep"], "ws_connecting")["p95"],
    "suback" => extract_trend(scenarios["chat-cold-upkeep"], "suback")["p95"],
    "setup_total" => extract_trend(scenarios["chat-cold-upkeep"], "setup_total")["p95"]
  },
  "turbo" => {
    "login_http" => extract_trend(scenarios["chat-cold-turbo"], "login_latency")["p95"],
    "page_request" => extract_trend(scenarios["chat-cold-turbo"], "page_render")["p95"],
    "ws_connecting" => extract_trend(scenarios["chat-cold-turbo"], "ws_connecting")["p95"],
    "suback" => extract_trend(scenarios["chat-cold-turbo"], "suback")["p95"],
    "setup_total" => extract_trend(scenarios["chat-cold-turbo"], "setup_total")["p95"]
  }
}

upkeep_cold_client_dominant = dominant_phase(cold_client_phases["upkeep"])
turbo_cold_client_dominant = dominant_phase(cold_client_phases["turbo"])
upkeep_cold_server_dominant = dominant_phase(cold_server_phases["upkeep"])
turbo_cold_server_dominant = dominant_phase(cold_server_phases["turbo"])

report = <<~MD
  # Matrix Benchmark Comparison

  **Generated:** #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}

  ## Chat: Warm Steady State

  Measures `POST /rooms/:id/messages -> observed delivery` after sessions,
  pages, sockets, and subscriptions are already established. Warm setup
  is admitted through a host-derived stagger schedule; setup that bleeds
  into the measured phase fails the workload.

  | Metric | Upkeep | Turbo |
  |--------|--------|-------|
  | RTT p50 (ms) | #{fmt extract_trend(scenarios["chat-warm-upkeep"], "rtt")["p50"]} | #{fmt extract_trend(scenarios["chat-warm-turbo"], "rtt")["p50"]} |
  | RTT p95 (ms) | #{fmt extract_trend(scenarios["chat-warm-upkeep"], "rtt")["p95"]} | #{fmt extract_trend(scenarios["chat-warm-turbo"], "rtt")["p95"]} |
  | RTT p99 (ms) | #{fmt extract_trend(scenarios["chat-warm-upkeep"], "rtt")["p99"]} | #{fmt extract_trend(scenarios["chat-warm-turbo"], "rtt")["p99"]} |
  | POST p50 (ms) | #{fmt extract_trend(scenarios["chat-warm-upkeep"], "post_latency")["p50"]} | #{fmt extract_trend(scenarios["chat-warm-turbo"], "post_latency")["p50"]} |
  | POST p95 (ms) | #{fmt extract_trend(scenarios["chat-warm-upkeep"], "post_latency")["p95"]} | #{fmt extract_trend(scenarios["chat-warm-turbo"], "post_latency")["p95"]} |
  | Setup leaks | #{fmt extract_counter(scenarios["chat-warm-upkeep"], "steady_state_setup_leaks")} | #{fmt extract_counter(scenarios["chat-warm-turbo"], "steady_state_setup_leaks")} |

  ## Chat: Cold Connect Churn

  Measures login + page + socket + subscribe pressure under churn. This
  workload does **not** report delivery latency as its primary result.

  | Client phase (p95 ms) | Upkeep | Turbo |
  |-----------------------|--------|-------|
  | Login HTTP | #{fmt extract_trend(scenarios["chat-cold-upkeep"], "login_latency")["p95"]} | #{fmt extract_trend(scenarios["chat-cold-turbo"], "login_latency")["p95"]} |
  | Page request | #{fmt extract_trend(scenarios["chat-cold-upkeep"], "page_render")["p95"]} | #{fmt extract_trend(scenarios["chat-cold-turbo"], "page_render")["p95"]} |
  | WebSocket connect | #{fmt extract_trend(scenarios["chat-cold-upkeep"], "ws_connecting")["p95"]} | #{fmt extract_trend(scenarios["chat-cold-turbo"], "ws_connecting")["p95"]} |
  | Subscribe ack | #{fmt extract_trend(scenarios["chat-cold-upkeep"], "suback")["p95"]} | #{fmt extract_trend(scenarios["chat-cold-turbo"], "suback")["p95"]} |
  | Setup total | #{fmt extract_trend(scenarios["chat-cold-upkeep"], "setup_total")["p95"]} | #{fmt extract_trend(scenarios["chat-cold-turbo"], "setup_total")["p95"]} |

  | Server phase (p95 ms) | Upkeep | Turbo |
  |-----------------------|--------|-------|
  | `sessions#create` | #{fmt cold_server_phases["upkeep"]["sessions#create"]} | #{fmt cold_server_phases["turbo"]["sessions#create"]} |
  | `rooms#show` | #{fmt cold_server_phases["upkeep"]["rooms#show"]} | #{fmt cold_server_phases["turbo"]["rooms#show"]} |
  | Cable connect | #{fmt cold_server_phases["upkeep"]["cable connect"]} | #{fmt cold_server_phases["turbo"]["cable connect"]} |
  | Subscription registration | #{fmt cold_server_phases["upkeep"]["subscription registration"]} | #{fmt cold_server_phases["turbo"]["subscription registration"]} |
  | Subscription confirmation | #{fmt cold_server_phases["upkeep"]["subscription confirmation"]} | #{fmt cold_server_phases["turbo"]["subscription confirmation"]} |

  Dominant client phase:
  Upkeep: #{upkeep_cold_client_dominant ? "#{upkeep_cold_client_dominant[0]} p95 #{fmt upkeep_cold_client_dominant[1]} ms" : "—"}
  Turbo: #{turbo_cold_client_dominant ? "#{turbo_cold_client_dominant[0]} p95 #{fmt turbo_cold_client_dominant[1]} ms" : "—"}

  Dominant server phase:
  Upkeep: #{upkeep_cold_server_dominant ? "#{upkeep_cold_server_dominant[0]} p95 #{fmt upkeep_cold_server_dominant[1]} ms" : "—"}
  Turbo: #{turbo_cold_server_dominant ? "#{turbo_cold_server_dominant[0]} p95 #{fmt turbo_cold_server_dominant[1]} ms" : "—"}

  ## Board

  | Metric | Upkeep | Turbo |
  |--------|--------|-------|
  | RTT p50 (ms) | #{fmt extract_trend(scenarios["board-upkeep"], "rtt")["p50"]} | #{fmt extract_trend(scenarios["board-turbo"], "rtt")["p50"]} |
  | RTT p95 (ms) | #{fmt extract_trend(scenarios["board-upkeep"], "rtt")["p95"]} | #{fmt extract_trend(scenarios["board-turbo"], "rtt")["p95"]} |
  | PATCH p50 (ms) | #{fmt extract_trend(scenarios["board-upkeep"], "patch_latency")["p50"]} | #{fmt extract_trend(scenarios["board-turbo"], "patch_latency")["p50"]} |
  | PATCH p95 (ms) | #{fmt extract_trend(scenarios["board-upkeep"], "patch_latency")["p95"]} | #{fmt extract_trend(scenarios["board-turbo"], "patch_latency")["p95"]} |
  | Broadcasts received | #{fmt extract_counter(scenarios["board-upkeep"], "broadcasts_rcvd")} | #{fmt extract_counter(scenarios["board-turbo"], "broadcasts_rcvd")} |

  ## Server-Side Metrics (whole run)

  | Metric | Upkeep | Turbo |
  |--------|--------|-------|
  | Avg render (ms) | #{fmt server["upkeep"]["avg_render_ms"]} | #{fmt server["turbo"]["avg_render_ms"]} |
  | Total renders | #{fmt server["upkeep"]["render_count"]} | #{fmt server["turbo"]["render_count"]} |
  | Avg payload (bytes) | #{fmt server["upkeep"]["avg_payload_bytes"]} | #{fmt server["turbo"]["avg_payload_bytes"]} |
  | Peak RSS (MB) | #{fmt server["upkeep"]["peak_rss_mb"]} | #{fmt server["turbo"]["peak_rss_mb"]} |

  ## Server-Side Metrics (polled endpoint)

  | Metric | Upkeep | Turbo |
  |--------|--------|-------|
  | RSS before (MB) | #{fmt polled["upkeep"]["rss_before_mb"]} | #{fmt polled["turbo"]["rss_before_mb"]} |
  | RSS final (MB) | #{fmt polled["upkeep"]["rss_final_mb"]} | #{fmt polled["turbo"]["rss_final_mb"]} |
  | GC count | #{fmt polled["upkeep"]["gc_count"]} | #{fmt polled["turbo"]["gc_count"]} |
  | Major GC count | #{fmt polled["upkeep"]["major_gc_count"]} | #{fmt polled["turbo"]["major_gc_count"]} |
  | Heap live slots | #{fmt polled["upkeep"]["heap_live_slots"]} | #{fmt polled["turbo"]["heap_live_slots"]} |
  | Total renders | #{fmt polled["upkeep"]["renders"]} | #{fmt polled["turbo"]["renders"]} |
  | Invalidations | #{fmt polled["upkeep"]["invalidations"]} | #{fmt polled["turbo"]["invalidations"]} |
  | Broadcasts | #{fmt polled["upkeep"]["broadcasts"]} | #{fmt polled["turbo"]["broadcasts"]} |
  | Transmits | #{fmt polled["upkeep"]["transmits"]} | #{fmt polled["turbo"]["transmits"]} |
  | Subscriptions (final) | #{fmt polled["upkeep"]["subscription_count"]} | #{fmt polled["turbo"]["subscription_count"]} |

  ## Upkeep Reactivity Surface

  | Metric | Value |
  |--------|-------|
  | Stored subscription graphs | #{fmt polled["upkeep"]["reactivity_subscriptions"]} |
  | Frames | #{fmt polled["upkeep"]["reactivity_frames"]} |
  | Dependencies | #{fmt polled["upkeep"]["reactivity_dependencies"]} |
  | Replay recipes | #{fmt polled["upkeep"]["reactivity_replay_recipes"]} |
  | Replay recipe bytes (total) | #{fmt polled["upkeep"]["reactivity_replay_recipe_bytes_total"]} |
  | Replay recipe bytes (max) | #{fmt polled["upkeep"]["reactivity_replay_recipe_bytes_max"]} |
  | Ambient replay inputs | #{fmt polled["upkeep"]["reactivity_ambient_replay_inputs"]} |
  | Ambient replay inputs by source | #{fmt polled["upkeep"]["reactivity_ambient_replay_inputs_by_source"]} |
  | Dependency sources | #{fmt polled["upkeep"]["reactivity_dependency_sources"]} |
  | Refused boundaries | #{fmt polled["upkeep"]["reactivity_refused_boundaries"]} |
  | Refused boundaries by reason | #{fmt polled["upkeep"]["reactivity_refused_boundaries_by_reason"]} |
  | Live deoptimizations | #{fmt polled["upkeep"]["reactivity_live_deoptimizations"]} |
  | Live deoptimizations by reason | #{fmt polled["upkeep"]["reactivity_live_deoptimizations_by_reason"]} |
  | Runtime render groups | #{fmt polled["upkeep"]["reactivity_render_groups"]} |
  | Runtime render count | #{fmt polled["upkeep"]["reactivity_render_count"]} |

  ## Dispatch Dedup (Upkeep only)

  | Metric | Value |
  |--------|-------|
  | Render groups dispatched | #{fmt polled["upkeep"]["relay_render_groups_total"]} |
  | Subscriber-renders saved by dedup | #{fmt polled["upkeep"]["relay_render_dedup_savings_total"]} |
  | Dedup ratio (savings / subs_served) | #{fmt polled["upkeep"]["relay_dedup_ratio"]} |
  | Client frames enqueued | #{fmt polled["upkeep"]["relay_client_frames"]} |
  | Client frames dropped (no connection) | #{fmt polled["upkeep"]["relay_client_frames_dropped_no_connection"]} |
  | Render groups (mode=request_free) | #{fmt polled["upkeep"]["relay_render_mode_request_free"]} |
  | Render groups (mode=synthetic_request) | #{fmt polled["upkeep"]["relay_render_mode_synthetic_request"]} |
  | Render groups (mode=page_replay) | #{fmt polled["upkeep"]["relay_render_mode_page_replay"]} |

  ## Methodology

  - `warm_steady_state_chat` pre-establishes sessions and subscriptions, then measures only write-to-observed-delivery.
  - `cold_connect_churn_chat` measures login, page, WebSocket connect, and subscribe pressure under churn.
  - Server timing seams come from benchmark-owned notifications in controllers, ActionCable connection setup, subscription registration, and subscription confirmation.
  - Scenario windows are attributed from `/bench/metrics` timestamps plus per-event `wall_time_ms` in server JSONL.
  - Upkeep fanout cost (`delivery_payload_serializations_total`, `delivery_payload_bytes_total`, `delivery_fanout_recipients_total`, plus the `delivery_fanout_duration_seconds` and `delivery_per_connection_enqueue_seconds` histograms) is the dispatch delivery surface — see the Memory Ceiling report's "Fanout Cost Attribution" section.
MD

output_path = File.join(results_dir, "matrix-compare-#{timestamp}.md")
File.write(output_path, report)
puts report
puts ""
puts "Written to: #{output_path}"
