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

def integer_env(key, default)
  Integer(ENV.fetch(key, default))
rescue ArgumentError
  default
end

def listen_backlog
  return Integer(ENV["LISTEN_BACKLOG"]) if ENV["LISTEN_BACKLOG"]

  Integer(`sysctl -n kern.ipc.somaxconn 2>/dev/null || sysctl -n net.core.somaxconn 2>/dev/null || echo 128`.strip)
rescue ArgumentError
  128
end

def admission_capacity
  worker_capacity = [1, integer_env("PUMA_WORKERS", 1) * integer_env("PUMA_THREADS", 5)].max
  backlog = [worker_capacity, listen_backlog].max
  admission_ceiling = [worker_capacity, [backlog, worker_capacity * 8].min].max
  {
    "worker_capacity" => worker_capacity,
    "backlog" => backlog,
    "admission_ceiling" => admission_ceiling
  }
end

def compute_admission_waves(target, worker_capacity:, admission_ceiling:)
  waves = []
  admitted = 0
  wave_size = worker_capacity
  while admitted < target
    remaining = target - admitted
    size = [remaining, [worker_capacity, [admission_ceiling, wave_size].min].max].min
    waves << size
    admitted += size
    wave_size = [admission_ceiling, wave_size * 2].min
  end
  waves
end

def warm_setup_profile(vus)
  tier = ENV.fetch("BENCH_TIER", "gate")
  stage_interval_ms = { "gate" => 2000, "report" => 4000 }.fetch(tier, 2000)
  settle_ms = { "gate" => 5000, "report" => 10_000 }.fetch(tier, 5000)
  capacity = admission_capacity
  waves = compute_admission_waves(
    vus.to_i,
    worker_capacity: capacity.fetch("worker_capacity"),
    admission_ceiling: capacity.fetch("admission_ceiling")
  )

  capacity.merge(
    "tier" => tier,
    "vus" => vus.to_i,
    "stage_interval_ms" => stage_interval_ms,
    "settle_ms" => settle_ms,
    "setup_window_ms" => (waves.length * stage_interval_ms) + settle_ms,
    "waves" => waves
  )
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

def summarize(values)
  values = values.compact.map(&:to_f).sort
  return {} if values.empty?

  percentile = lambda do |ratio|
    index = [(values.length * ratio).ceil - 1, 0].max
    values.fetch([index, values.length - 1].min)
  end

  {
    "count" => values.length,
    "avg_ms" => (values.sum / values.length).round(3),
    "p95_ms" => percentile.call(0.95).round(3),
    "max_ms" => values.last.round(3)
  }
end

def load_server_events(results_dir, app_name, run_timestamp)
  files = Dir.glob(File.join(results_dir, "server-#{app_name}-*.jsonl")).select do |path|
    suffix = File.basename(path)[/server-#{app_name}-(\d{14})\.jsonl\z/, 1]
    suffix && suffix >= run_timestamp
  end
  return [] if files.empty?

  File.readlines(files.min).filter_map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end
end

def event_field_stats(events, event_name, field, filters = {})
  values = events.filter_map do |event|
    next unless event["event"] == event_name
    next unless filters.all? { |key, value| event[key.to_s] == value }

    event[field]
  end

  summarize(values)
end

def server_phase_summary(events)
  {
    "setup_page_request" => event_field_stats(events, "bench_request", "duration_ms", phase: "feed#show", bench_phase: "setup_page"),
    "setup_page_client_to_server_start" => event_field_stats(events, "bench_request", "client_to_server_start_ms", phase: "feed#show", bench_phase: "setup_page"),
    "refresh_page_request" => event_field_stats(events, "bench_request", "duration_ms", phase: "feed#show", bench_phase: "refresh_get"),
    "refresh_page_client_to_server_start" => event_field_stats(events, "bench_request", "client_to_server_start_ms", phase: "feed#show", bench_phase: "refresh_get"),
    "cable_request" => event_field_stats(events, "bench_cable_request", "duration_ms"),
    "cable_request_client_to_server_start" => event_field_stats(events, "bench_cable_request", "client_to_server_start_ms"),
    "cable_open" => event_field_stats(events, "bench_cable_open", "duration_ms"),
    "cable_open_client_to_server_start" => event_field_stats(events, "bench_cable_open", "client_to_server_start_ms"),
    "subscription_registration" => event_field_stats(events, "bench_subscription_registration", "duration_ms"),
    "subscription_registration_client_to_server_start" => event_field_stats(events, "bench_subscription_registration", "client_to_server_start_ms"),
    "subscription_confirmation" => event_field_stats(events, "bench_subscription_confirmation", "duration_ms"),
    "write_request" => event_field_stats(events, "bench_request", "duration_ms", phase: "feed#create", bench_phase: "write_post"),
    "write_client_to_server_start" => event_field_stats(events, "bench_request", "client_to_server_start_ms", phase: "feed#create", bench_phase: "write_post")
  }
end

upkeep_entries = load_jsonl(File.join(results_dir, "metrics-upkeep-#{timestamp}.jsonl"))
upkeep_k6 = load_json(File.join(results_dir, "render-dedup-identity-free-feed-upkeep.json"))
turbo_k6 = load_json(File.join(results_dir, "render-dedup-identity-free-feed-turbo.json"))
upkeep_server_events = load_server_events(results_dir, "upkeep", timestamp)
turbo_server_events = load_server_events(results_dir, "turbo", timestamp)

upkeep_before = metric_data(upkeep_entries, "before")
upkeep_after = metric_data(upkeep_entries, "after-render-dedup-identity-free-feed-compare-upkeep")
upkeep_reactivity = upkeep_after["upkeep_reactivity"] || {}
upkeep_graph = upkeep_reactivity["subscription_graphs"] || {}
upkeep_delivery = upkeep_reactivity["delivery"] || {}
upkeep_identity = upkeep_reactivity["subscription_identity"] || {}
upkeep_request_capture = upkeep_reactivity["request_capture"] || {}
upkeep_shapes = upkeep_reactivity["subscription_shapes"] || {}
upkeep_subscribe = upkeep_reactivity["subscription_subscribe"] || {}
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
observed_vus = [
  k6_metric(upkeep_k6, "vus", "value"),
  k6_metric(upkeep_k6, "vus_max", "value"),
  k6_metric(turbo_k6, "vus", "value"),
  ENV["BENCH_VUS"]
].compact.first&.to_i
setup_profile = warm_setup_profile(observed_vus || 0)
relay_metrics_available = relay_render_groups.positive?
delivery_bytes = relay_metrics_available ? counter_delta(upkeep_before, upkeep_after, "delivery_payload_bytes_total") : nil
client_frames_sent = relay_metrics_available ? counter_delta(upkeep_before, upkeep_after, "client_frames_sent_total") : nil
relay_note = relay_metrics_available ? "" : "\nRelay metrics were unavailable in this run, so the Upkeep render-group row uses the app-local delivery counters.\n"

report = {
  "timestamp" => timestamp,
  "vus" => observed_vus,
  "warm_setup_profile" => setup_profile,
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
    "steady_state_setup_leaks" => k6_metric(upkeep_k6, "steady_state_setup_leaks", "count"),
    "ws_connect_p95_ms" => k6_metric(upkeep_k6, "ws_connect", "p(95)"),
    "subscribe_latency_p95_ms" => k6_metric(upkeep_k6, "subscribe_latency", "p(95)"),
    "suback_p95_ms" => k6_metric(upkeep_k6, "suback", "p(95)"),
    "server_phases" => server_phase_summary(upkeep_server_events),
    "render_groups_by_tier" => labelled_delta(upkeep_before, upkeep_after, "render_groups_by_tier"),
    "render_groups_by_mode" => labelled_delta(upkeep_before, upkeep_after, "render_groups_by_mode"),
    "reactivity" => {
      "subscriptions" => upkeep_graph["subscriptions"],
      "frames" => upkeep_graph["frames"],
      "dependencies" => upkeep_graph["dependencies"],
      "shared_stream_names" => upkeep_graph["shared_stream_names"],
      "relay_metrics_available" => relay_metrics_available,
      "plans" => upkeep_delivery["plans"],
      "planned_targets" => upkeep_delivery["planned_targets"],
      "represented_subscribers" => upkeep_delivery["represented_subscribers"],
      "stream_batches" => upkeep_delivery["stream_batches"],
      "runtime_render_groups" => upkeep_delivery["render_groups"],
      "runtime_render_count" => upkeep_delivery["render_count"],
      "live_deoptimizations" => upkeep_live_deoptimizations
    },
    "subscription_identity" => upkeep_identity,
    "request_capture" => upkeep_request_capture,
    "subscription_shapes" => upkeep_shapes,
    "subscription_subscribe" => upkeep_subscribe
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
    "steady_state_setup_leaks" => k6_metric(turbo_k6, "steady_state_setup_leaks", "count"),
    "ws_connect_p95_ms" => k6_metric(turbo_k6, "ws_connect", "p(95)"),
    "subscribe_latency_p95_ms" => k6_metric(turbo_k6, "subscribe_latency", "p(95)"),
    "suback_p95_ms" => k6_metric(turbo_k6, "suback", "p(95)"),
    "server_phases" => server_phase_summary(turbo_server_events)
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
  Warm setup: #{fmt(setup_profile["setup_window_ms"])} ms window, #{fmt(setup_profile["stage_interval_ms"])} ms wave interval, #{fmt(setup_profile["settle_ms"])} ms settle.
  Admission waves: `#{setup_profile["waves"].join(", ")}`

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
  | Setup leaks after warm window | #{fmt(upkeep["steady_state_setup_leaks"])} | #{fmt(turbo["steady_state_setup_leaks"])} |
  | Setup p95 ms | #{fmt(upkeep["setup_p95_ms"])} | #{fmt(turbo["setup_p95_ms"])} |
  | Page render p95 ms | #{fmt(upkeep["page_render_p95_ms"])} | #{fmt(turbo["page_render_p95_ms"])} |
  | WS connect p95 ms | #{fmt(upkeep["ws_connect_p95_ms"])} | #{fmt(turbo["ws_connect_p95_ms"])} |
  | Subscribe call p95 ms | #{fmt(upkeep["subscribe_latency_p95_ms"])} | #{fmt(turbo["subscribe_latency_p95_ms"])} |
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
  | Plans | #{fmt(upkeep.dig("reactivity", "plans"))} |
  | Stream batches | #{fmt(upkeep.dig("reactivity", "stream_batches"))} |
  | Runtime render groups | #{fmt(upkeep.dig("reactivity", "runtime_render_groups"))} |
  | Runtime render count | #{fmt(upkeep.dig("reactivity", "runtime_render_count"))} |
  | Planned targets | #{fmt(upkeep.dig("reactivity", "planned_targets"))} |
  | Represented subscribers | #{fmt(upkeep.dig("reactivity", "represented_subscribers"))} |
  | Live delivery deopts | `#{upkeep.dig("reactivity", "live_deoptimizations") || {}}` |
  | Render groups by tier | `#{upkeep["render_groups_by_tier"]}` |
  | Render groups by mode | `#{upkeep["render_groups_by_mode"]}` |
  | Subscription identity modes | `#{upkeep.dig("subscription_identity", "by_mode") || {}}` |
  | Anonymous deopts | `#{upkeep.dig("subscription_identity", "anonymous_deopts") || {}}` |
  | Request capture timings | `#{upkeep.dig("request_capture", "timings") || {}}` |
  | Request capture by operation | `#{upkeep.dig("request_capture", "by_operation") || {}}` |
  | Subscription shape cache | `#{upkeep["subscription_shapes"] || {}}` |
  | Subscription shape timings | `#{upkeep.dig("subscription_shapes", "timings") || {}}` |
  | Subscribe channel timings | `#{upkeep.dig("subscription_subscribe", "timings") || {}}` |
  | Stored subscriptions | #{fmt(upkeep.dig("reactivity", "subscriptions"))} |
  | Shared stream names | #{fmt(upkeep.dig("reactivity", "shared_stream_names"))} |

  ## Server/Client Phase Correlation

  | Phase | Upkeep | Turbo |
  | --- | ---: | ---: |
  | Setup page request server p95 ms | #{fmt(upkeep.dig("server_phases", "setup_page_request", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "setup_page_request", "p95_ms"))} |
  | Setup page client-to-server start p95 ms | #{fmt(upkeep.dig("server_phases", "setup_page_client_to_server_start", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "setup_page_client_to_server_start", "p95_ms"))} |
  | Refresh page request server p95 ms | #{fmt(upkeep.dig("server_phases", "refresh_page_request", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "refresh_page_request", "p95_ms"))} |
  | Refresh page client-to-server start p95 ms | #{fmt(upkeep.dig("server_phases", "refresh_page_client_to_server_start", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "refresh_page_client_to_server_start", "p95_ms"))} |
  | Cable request server p95 ms | #{fmt(upkeep.dig("server_phases", "cable_request", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "cable_request", "p95_ms"))} |
  | Cable open server p95 ms | #{fmt(upkeep.dig("server_phases", "cable_open", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "cable_open", "p95_ms"))} |
  | Subscription registration server p95 ms | #{fmt(upkeep.dig("server_phases", "subscription_registration", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "subscription_registration", "p95_ms"))} |
  | Subscription registration client-to-server start p95 ms | #{fmt(upkeep.dig("server_phases", "subscription_registration_client_to_server_start", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "subscription_registration_client_to_server_start", "p95_ms"))} |
  | Subscription confirmation server p95 ms | #{fmt(upkeep.dig("server_phases", "subscription_confirmation", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "subscription_confirmation", "p95_ms"))} |
  | Write request server p95 ms | #{fmt(upkeep.dig("server_phases", "write_request", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "write_request", "p95_ms"))} |
  | Write client-to-server start p95 ms | #{fmt(upkeep.dig("server_phases", "write_client_to_server_start", "p95_ms"))} | #{fmt(turbo.dig("server_phases", "write_client_to_server_start", "p95_ms"))} |

  ## Reading the comparison

  This is the high-sharing shape where Upkeep should have room to close
  or beat Turbo: one shared, identity-free write fans out to many
  subscribers. Turbo's standard refresh path turns each subscriber event
  into a page GET. Upkeep should collapse the render work and ship
  subscriber deliveries from the registered reactive graph.
MARKDOWN

puts "Identity-free feed compare report: #{md_path}"
