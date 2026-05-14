# frozen_string_literal: true

# Emits a compact smoke-<timestamp>.md from the upkeep metrics JSONL
# collected by benchmark/bin/run's poll_metrics. Consumed by assert_dedup.rb.
#
# This is the smoke e2e gate — not a benchmark. It boots upkeep-app
# under Puma + dispatch, drives one k6 scenario, and records whether
# the dedup/fragment counters crossed regression thresholds. There is
# no turbo side and no comparison — comparison lives in compare.rb
# and the full benchmark report.
#
# Counters are emitted as per-run deltas (final − before) rather than
# raw cumulative values. Dispatch's Prometheus counters are
# process-lifetime cumulative, so a raw "render groups = 0" could
# mean "nothing happened this run" OR "nothing has ever happened";
# a delta disambiguates and makes the assertion "this run produced
# at least one render group" structurally meaningful.

require "json"

results_dir = ARGV[0] or abort("usage: ruby smoke_summary.rb <results-dir> <timestamp>")
timestamp   = ARGV[1] or abort("usage: ruby smoke_summary.rb <results-dir> <timestamp>")

metrics_path = File.join(results_dir, "metrics-upkeep-#{timestamp}.jsonl")
abort("no metrics file: #{metrics_path}") unless File.exist?(metrics_path)

records = File.readlines(metrics_path).filter_map { |l| begin
                                                   JSON.parse(l)
                                                 rescue
                                                   nil
                                                 end }
abort("metrics-upkeep-#{timestamp}.jsonl is empty") if records.empty?

before = records.find { |r| r["label"] == "before" } or
  abort("metrics-upkeep-#{timestamp}.jsonl missing 'before' record")
final = records.find { |r| r["label"] == "final" } or
  abort("metrics-upkeep-#{timestamp}.jsonl missing 'final' record")

before_relay = before.dig("data", "relay") || {}
final_relay = final.dig("data", "relay") || {}
reactivity = final.dig("data", "upkeep_reactivity") || {}
graph = reactivity["subscription_graphs"] || {}
ambient = graph["ambient_replay_inputs"] || {}
refused = reactivity["refused_boundaries"] || {}
delivery = reactivity["delivery"] || {}
live_deopts = delivery["live_deoptimizations"] || {}

# Only dispatch-wide counters are delta-safe. Per-worker counters
# (`renders`, `invalidations`) come from `/bench/metrics`, which hits
# one random Puma worker per scrape — subtracting two worker snapshots
# that hit different workers produces noise (can even go negative).
# The gate asserts on dispatch-wide metrics, so the app-local rows are
# left out of the summary.
delta = ->(container, key) { container.fetch(key, 0).to_i }
delta_counter = lambda do |key|
  delta.call(final_relay.fetch("counters", {}), key) - delta.call(before_relay.fetch("counters", {}), key)
end
diff_map = lambda do |section|
  before_map = before_relay.fetch(section, {})
  final_map = final_relay.fetch(section, {})
  (before_map.keys | final_map.keys).each_with_object({}) do |key, out|
    out[key] = final_map.fetch(key, 0).to_i - before_map.fetch(key, 0).to_i
  end
end
nested_diff_map = lambda do |outer_section, inner_section|
  before_map = before_relay.dig(outer_section, inner_section) || {}
  final_map = final_relay.dig(outer_section, inner_section) || {}
  (before_map.keys | final_map.keys).each_with_object({}) do |key, out|
    out[key] = final_map.fetch(key, 0).to_i - before_map.fetch(key, 0).to_i
  end
end

groups  = delta_counter.call("render_groups_total")
savings = delta_counter.call("render_dedup_savings_total")
frames  = delta_counter.call("client_frames_sent_total")
dropped = delta_counter.call("client_frames_dropped_no_connection_total")
closed = delta_counter.call("client_frames_closed_total")
overflow = delta_counter.call("client_frames_dropped_overflow_total")
without_payload = delta_counter.call("delivery_sids_without_payload_total")
render_errors = delta_counter.call("render_call_errors_total")
payload_serializations = delta_counter.call("delivery_payload_serializations_total")
payload_bytes_total = delta_counter.call("delivery_payload_bytes_total")
fanout_recipients = delta_counter.call("delivery_fanout_recipients_total")
sharing_factor = payload_serializations.zero? ? nil : (fanout_recipients.to_f / payload_serializations).round(2)
avg_payload_bytes = payload_serializations.zero? ? nil : (payload_bytes_total.to_f / payload_serializations).round(1)
fanout_duration = final_relay.dig("fanout", "duration") || {}
per_conn_enqueue = final_relay.dig("fanout", "per_connection_enqueue") || {}

tiers = diff_map.call("render_groups_by_tier")
modes = diff_map.call("render_groups_by_mode")
render_calls_by_mode = diff_map.call("render_calls_by_mode")

tier_none       = tiers.fetch("none", 0)
tier_user_keyed = tiers.fetch("user-keyed", 0)
mode_request_free      = modes.fetch("request_free", 0)
mode_synthetic_request = modes.fetch("synthetic_request", 0)
mode_page_replay       = modes.fetch("page_replay", 0)
render_call_request_free       = render_calls_by_mode.fetch("request_free", 0)
render_call_synthetic_request  = render_calls_by_mode.fetch("synthetic_request", 0)
render_call_page_replay        = render_calls_by_mode.fetch("page_replay", 0)
replay_forced          = delta_counter.call("replay_forced_groups_total")
downgrades             = delta_counter.call("classification_downgrades_total")

proof_reason_deltas = nested_diff_map.call("proof_fallback", "by_reason")
runtime_mode_deltas = nested_diff_map.call("runtime_contradiction", "by_mode")

# Dedup ratio is not a counter — recompute from the delta values. Guards
# the zero-both case: if no groups and no savings, ratio is meaningless.
subs_served = groups + savings
ratio = subs_served.zero? ? nil : (savings.to_f / subs_served).round(4)

summary = <<~MD
  # Smoke e2e — #{timestamp}

  End-to-end regression gate. Boots upkeep-app under Puma + dispatch,
  runs one k6 board scenario, asserts dispatch counters. Not a
  benchmark — no turbo comparison.

  Values below are per-run deltas (final − before) of dispatch-wide
  Prometheus counters. Deltas isolate what this run did from the
  dispatch's lifetime state.

  ## Dispatch Dedup (Upkeep only)

  | Metric | Value |
  |--------|-------|
  | Render groups dispatched | #{groups} |
  | Subscriber-renders saved by dedup | #{savings} |
  | Dedup ratio (savings / subs_served) | #{ratio || "—"} |
  | Client frames enqueued | #{frames} |
  | Client frames dropped (no connection) | #{dropped} |
  | Client frames closed | #{closed} |
  | Client frames dropped (overflow) | #{overflow} |
  | Delivery sids without payload | #{without_payload} |
  | Render call errors | #{render_errors} |
  | Payload serializations | #{payload_serializations} |
  | Payload bytes packed (total) | #{payload_bytes_total} |
  | Avg payload bytes per serialization | #{avg_payload_bytes || "—"} |
  | Fanout recipients (sum) | #{fanout_recipients} |
  | Sharing factor (recipients / serialization) | #{sharing_factor || "—"} |
  | Fanout duration p95 (s) | #{fanout_duration["p95_upper_bound_seconds"] || "—"} |
  | Per-connection enqueue p95 (s) | #{per_conn_enqueue["p95_upper_bound_seconds"] || "—"} |
  | Render groups (tier=none) | #{tier_none} |
  | Render groups (tier=user-keyed) | #{tier_user_keyed} |
  | Render groups (mode=request_free) | #{mode_request_free} |
  | Render groups (mode=synthetic_request) | #{mode_synthetic_request} |
  | Render groups (mode=page_replay) | #{mode_page_replay} |
  | Render calls (mode=request_free) | #{render_call_request_free} |
  | Render calls (mode=synthetic_request) | #{render_call_synthetic_request} |
  | Render calls (mode=page_replay) | #{render_call_page_replay} |
  | Replay-forced groups | #{replay_forced} |
  | Classification downgrades | #{downgrades} |

  ## Reactivity Surface

  | Metric | Value |
  |--------|-------|
  | Stored subscription graphs | #{graph["subscriptions"] || "—"} |
  | Frames | #{graph["frames"] || "—"} |
  | Dependencies | #{graph["dependencies"] || "—"} |
  | Replay recipes | #{graph["replay_recipes"] || "—"} |
  | Replay recipe bytes (total) | #{graph["replay_recipe_bytes_total"] || "—"} |
  | Replay recipe bytes (max) | #{graph["replay_recipe_bytes_max"] || "—"} |
  | Ambient replay inputs | #{ambient["total"] || "—"} |
  | Ambient replay inputs by source | #{ambient["by_source"] || "—"} |
  | Dependency sources | #{graph["dependency_sources"] || "—"} |
  | Refused boundaries | #{refused["total"] || "—"} |
  | Refused boundaries by reason | #{refused["by_reason"] || "—"} |
  | Live deoptimizations | #{live_deopts["total"] || "—"} |
  | Live deoptimizations by reason | #{live_deopts["by_reason"] || "—"} |
  | Runtime render groups | #{delivery["render_groups"] || "—"} |
  | Runtime render count | #{delivery["render_count"] || "—"} |

  ## De-Opt Reasons

  | Metric | Value |
  |--------|-------|
  | Proof fallbacks (predicate_touched) | #{proof_reason_deltas.fetch("predicate_touched", 0)} |
  | Proof fallbacks (canonical_unknown) | #{proof_reason_deltas.fetch("canonical_unknown", 0)} |
  | Runtime contradictions (synthetic_request) | #{runtime_mode_deltas.fetch("synthetic_request", 0)} |
  | Runtime contradictions (page_replay) | #{runtime_mode_deltas.fetch("page_replay", 0)} |
MD

out = File.join(results_dir, "smoke-#{timestamp}.md")
File.write(out, summary)
puts "Wrote #{out}"
