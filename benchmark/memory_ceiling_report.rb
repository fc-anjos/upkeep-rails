#!/usr/bin/env ruby
# frozen_string_literal: true

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

def metric_wall_time_ms(entry)
  return entry["wall_time_ms"].to_f if entry["wall_time_ms"]
  return unless entry["timestamp"]

  Time.parse(entry["timestamp"]).to_f * 1000
rescue ArgumentError
  nil
end

def run_wall_time_bounds(entries)
  times = entries.filter_map { |entry| metric_wall_time_ms(entry) }
  return if times.empty?

  [ times.min, times.max ]
end

def in_run_wall_time?(event, bounds)
  return true unless bounds

  wall_time_ms = event["wall_time_ms"]
  return false unless wall_time_ms

  wall_time_ms.to_f.between?(bounds.first, bounds.last)
end

def server_events_for_run(results_dir, app_name, timestamp, bounds: nil)
  Dir.glob(File.join(results_dir, "server-#{app_name}-*.jsonl"))
    .select { |path| File.basename(path)[/\d{14}/].to_s >= timestamp }
    .flat_map { |path| load_jsonl(path) }
    .select { |event| in_run_wall_time?(event, bounds) }
    .sort_by { |event| event["wall_time_ms"].to_f }
end

def metric_entries(results_dir, app_name, timestamp)
  load_jsonl(File.join(results_dir, "metrics-#{app_name}-#{timestamp}.jsonl"))
end

def metric_data(entries, label)
  entries.find { |entry| entry["label"] == label }&.dig("data") || {}
end

def rss_summary(records)
  return {} if records.empty?

  app = records.map { |record| record["app_rss_kb"].to_i }
  combined = records.map { |record| record.fetch("combined_rss_kb", record["app_rss_kb"]).to_i }

  {
    "static_app_mb" => (app.first / 1024.0).round(1),
    "peak_app_mb" => (app.max / 1024.0).round(1),
    "peak_combined_mb" => (combined.max / 1024.0).round(1),
    "samples" => records.size
  }
end

def process_rss_summary(records)
  by_role = Hash.new { |roles, role| roles[role] = { samples: [], max_processes: 0 } }

  records.each do |record|
    processes = Array(record["processes"])
    next if processes.empty?

    processes.group_by { |process| process["role"].to_s }.each do |role, role_processes|
      next if role.empty?

      total_rss_kb = role_processes.sum { |process| process["rss_kb"].to_i }
      by_role[role][:samples] << total_rss_kb
      by_role[role][:max_processes] = [ by_role[role][:max_processes], role_processes.size ].max
    end
  end

  roles = by_role.each_with_object({}) do |(role, data), summary|
    samples = data[:samples]
    next if samples.empty?

    summary[role] = {
      "peak_mb" => (samples.max / 1024.0).round(1),
      "avg_mb" => ((samples.sum / samples.size.to_f) / 1024.0).round(1),
      "max_processes" => data[:max_processes]
    }
  end

  { "roles" => roles }
end

def role_rss_mb(record, role)
  Array(record["processes"])
    .select { |process| process["role"].to_s == role }
    .sum { |process| process["rss_kb"].to_i } / 1024.0
end

def rss_owner_summary(records)
  return {} if records.empty?

  owners = {
    "request_workers" => "upkeep_puma_worker",
    "render_runtime" => "upkeep_render_runtime"
  }

  owners.each_with_object({}) do |(owner, role), summary|
    samples = records.map { |record| role_rss_mb(record, role) }
    next if samples.empty?

    summary[owner] = {
      "peak_mb" => samples.max.round(1),
      "avg_mb" => (samples.sum / samples.size.to_f).round(1)
    }
  end
end

def phase_rss_summary(phases, rss_records)
  return {} if phases.empty? || rss_records.empty?

  rss_records_by_time = rss_records
    .select { |record| record["timestamp"] }
    .sort_by { |record| record["timestamp"].to_f }

  phases.each_with_object({}) do |(phase, payload), summary|
    wall_time_ms = payload["wall_time_ms"]
    next unless wall_time_ms

    record = nearest_rss_record(rss_records_by_time, wall_time_ms.to_f)
    next unless record

    summary[phase] = {
      "request_workers_mb" => role_rss_mb(record, "upkeep_puma_worker").round(1),
      "render_runtime_mb" => role_rss_mb(record, "upkeep_render_runtime").round(1),
      "app_mb" => (record["app_rss_kb"].to_i / 1024.0).round(1),
      "combined_mb" => (record.fetch("combined_rss_kb", record["app_rss_kb"]).to_i / 1024.0).round(1),
      "sample_timestamp" => record["timestamp"]
    }
  end
end

def nearest_rss_record(records, wall_time_ms)
  records.min_by { |record| (record["timestamp"].to_f - wall_time_ms).abs }
end

def k6_metric(data, metric_name, key)
  data.dig("metrics", metric_name, "values", key)
end

def env_integer(name)
  value = ENV[name]
  return if value.nil? || value.empty?

  Integer(value)
rescue ArgumentError
  nil
end

def latest_memory_snapshot(events)
  events.reverse.find { |event| event["event"] == "upkeep_memory_snapshot" } || {}
end

def memory_payload(snapshot)
  {
    "phase" => snapshot["phase"],
    "wall_time_ms" => snapshot["wall_time_ms"],
    "rss_mb" => snapshot["rss_mb"],
    "heap_allocated_pages" => snapshot["heap_allocated_pages"],
    "heap_sorted_length" => snapshot["heap_sorted_length"],
    "heap_allocatable_pages" => snapshot["heap_allocatable_pages"],
    "heap_available_slots" => snapshot["heap_available_slots"],
    "heap_live_slots" => snapshot["heap_live_slots"],
    "heap_free_slots" => snapshot["heap_free_slots"],
    "total_allocated_objects" => snapshot["total_allocated_objects"],
    "total_freed_objects" => snapshot["total_freed_objects"],
    "gc_count" => snapshot["gc_count"],
    "major_gc_count" => snapshot["major_gc_count"],
    "malloc_increase_bytes" => snapshot["malloc_increase_bytes"],
    "malloc_increase_bytes_limit" => snapshot["malloc_increase_bytes_limit"],
    "old_objects" => snapshot["old_objects"],
    "oldmalloc_increase_bytes" => snapshot["oldmalloc_increase_bytes"],
    "oldmalloc_increase_bytes_limit" => snapshot["oldmalloc_increase_bytes_limit"],
    "objectspace_memsize_bytes" => snapshot["objectspace_memsize_bytes"],
    "action_cable_counts" => snapshot["action_cable_counts"] || {},
    "object_counts" => snapshot["object_counts"] || {},
    "upkeep_instance_counts" => snapshot["upkeep_instance_counts"] || {},
    "retained_owner_counts" => snapshot["retained_owner_counts"] || {},
    "allocation_delta" => snapshot["allocation_delta"] || {},
    "class_retention_bytes" => snapshot["class_retention_bytes"] || {},
    "allocation_sites" => snapshot["allocation_sites"] || {}
  }
end

PHASE_ORDER = %w[before after_subscribe after_writes after_drain final].freeze

def memory_phase_snapshots(events)
  phases = {}
  events.each do |event|
    next unless event["event"] == "upkeep_memory_snapshot"
    phase = event["phase"].to_s
    next if phase.empty?
    phases[phase] = memory_payload(event)
  end
  phases
end

def ordered_phase_pairs(phases)
  PHASE_ORDER.each_cons(2).filter_map do |from, to|
    [ from, to ] if phases[from] && phases[to]
  end
end

def numeric_delta(phases, from, to, key)
  phases.dig(to, key).to_i - phases.dig(from, key).to_i
end

def phase_deltas(phases)
  ordered_phase_pairs(phases).map do |from, to|
    {
      "from" => from,
      "to" => to,
      "heap_live_slots" => numeric_delta(phases, from, to, "heap_live_slots"),
      "heap_allocated_pages" => numeric_delta(phases, from, to, "heap_allocated_pages"),
      "heap_free_slots" => numeric_delta(phases, from, to, "heap_free_slots"),
      "allocated_objects" => numeric_delta(phases, from, to, "total_allocated_objects"),
      "old_objects" => numeric_delta(phases, from, to, "old_objects"),
      "oldmalloc_increase_bytes" => numeric_delta(phases, from, to, "oldmalloc_increase_bytes"),
      "objectspace_memsize_bytes" => numeric_delta(phases, from, to, "objectspace_memsize_bytes"),
      "gc_count" => numeric_delta(phases, from, to, "gc_count"),
      "major_gc_count" => numeric_delta(phases, from, to, "major_gc_count")
    }
  end
end

def retained_owner_deltas(phases, limit: 8)
  ordered_phase_pairs(phases).flat_map do |from, to|
    before = phases.dig(from, "retained_owner_counts") || {}
    after = phases.dig(to, "retained_owner_counts") || {}

    (before.keys | after.keys).map do |name|
      {
        "from" => from,
        "to" => to,
        "name" => name,
        "delta" => after[name].to_i - before[name].to_i
      }
    end
      .select { |entry| entry["delta"].positive? }
      .sort_by { |entry| -entry["delta"] }
      .first(limit)
  end
end

def event_rows(events, name)
  events.select { |event| event["event"] == name }
end

def percentile(values, percentile)
  values = values.compact.map(&:to_f).sort
  return nil if values.empty?

  index = ((values.size - 1) * percentile).ceil
  values[index].round(3)
end

def proof_proven_delta(before, after, reason)
  before_count = before.dig("relay", "proof_proven", "by_reason", reason).to_i
  after_count = after.dig("relay", "proof_proven", "by_reason", reason).to_i
  after_count - before_count
end

def counter_delta(before, after, name)
  after.dig("relay", "counters", name).to_i - before.dig("relay", "counters", name).to_i
end

def delivery_drain_summary(_events, before_metrics, after_metrics)
  fanout = fanout_summary(before_metrics, after_metrics)
  classification, next_optimization = fanout_classification(fanout)
  admissible = fanout["render_call_errors_delta"].to_i.zero?
  fanout.merge(
    "classification" => classification,
    "next_optimization" => next_optimization,
    "admissible" => admissible,
    "admissibility_reason" => admissible ? nil : "render_call_errors_total_delta_nonzero"
  )
end

# Fanout cost is the dispatch delivery surface: one
# `Envelope.encode_body(:client_delivery, ...)` per render group plus
# N `connection.enqueue(bytes)` calls. The summary captures the
# sharing factor (recipients per serialization) and the latency
# distribution of both phases so a regression in either shows up as
# an attributable signal.
def fanout_summary(before_metrics, after_metrics)
  serializations = counter_delta(before_metrics, after_metrics, "delivery_payload_serializations_total")
  recipients     = counter_delta(before_metrics, after_metrics, "delivery_fanout_recipients_total")
  bytes_total    = counter_delta(before_metrics, after_metrics, "delivery_payload_bytes_total")
  frames_sent    = counter_delta(before_metrics, after_metrics, "client_frames_sent_total")
  frames_dropped =
    counter_delta(before_metrics, after_metrics, "client_frames_dropped_no_connection_total") +
    counter_delta(before_metrics, after_metrics, "client_frames_closed_total") +
    counter_delta(before_metrics, after_metrics, "client_frames_dropped_overflow_total")

  client_acks = counter_delta(before_metrics, after_metrics, "client_acks_total")
  supersession = after_metrics.dig("relay", "fanout", "supersession_actions") || {}

  {
    "serializations_delta" => serializations,
    "recipients_delta" => recipients,
    "bytes_total_delta" => bytes_total,
    "frames_sent_delta" => frames_sent,
    "frames_dropped_delta" => frames_dropped,
    "client_acks_delta" => client_acks,
    "render_call_errors_delta" => counter_delta(before_metrics, after_metrics, "render_call_errors_total"),
    "sharing_factor" => serializations.zero? ? nil : (recipients.to_f / serializations).round(2),
    "avg_payload_bytes" => serializations.zero? ? nil : (bytes_total.to_f / serializations).round(1),
    "fanout_duration" => after_metrics.dig("relay", "fanout", "duration") || {},
    "per_connection_enqueue" => after_metrics.dig("relay", "fanout", "per_connection_enqueue") || {},
    "supersession_inserted" => supersession["inserted"].to_i,
    "supersession_replaced" => supersession["replaced"].to_i,
    "supersession_unchanged" => supersession["unchanged"].to_i
  }
end

# Coarse classifier on the new shape. Compares the per-recipient
# slice of `fanout_duration` (≈ serialization_cost / N + per_conn_enqueue)
# against the standalone `per_connection_enqueue` measurement. When
# the per-recipient slice exceeds ~3× the pure enqueue cost, the
# serialization step is the bottleneck; when they're close, the
# remaining cost is the linear N enqueues.
def fanout_classification(fanout)
  return [ "client_connection_drops", "connection_capacity_or_backpressure_review" ] if fanout["frames_dropped_delta"].to_i.positive?
  return [ "no_traffic_observed", "no_change_recommended" ] if fanout["recipients_delta"].to_i.zero?

  fanout_p95 = fanout.dig("fanout_duration", "p95_upper_bound_seconds").to_f
  per_conn_p95 = fanout.dig("per_connection_enqueue", "p95_upper_bound_seconds").to_f
  sharing = fanout["sharing_factor"].to_f
  return [ "no_sharing_observed", "review_dedup_invariants" ] if sharing < 1.0

  per_recipient = sharing.zero? ? 0.0 : fanout_p95 / sharing

  if per_conn_p95.positive? && per_recipient > 3 * per_conn_p95
    [ "fanout_serialization_dominated", "preencoded_or_zero_copy_envelope" ]
  elsif sharing >= 5.0
    [ "shared_payload_well_amortized", "no_change_recommended" ]
  else
    [ "fanout_per_connection_dominated", "parallel_per_connection_writes" ]
  end
end

def app_summary(results_dir, timestamp, app_name, after_label, k6_file, rss_file)
  entries = metric_entries(results_dir, app_name, timestamp)
  before = metric_data(entries, "before")
  after = metric_data(entries, after_label)
  k6 = load_json(File.join(results_dir, k6_file))
  rss_records = load_jsonl(File.join(results_dir, rss_file))
  rss = rss_summary(rss_records)
  server_events = server_events_for_run(results_dir, app_name, timestamp, bounds: run_wall_time_bounds(entries))
  phases = memory_phase_snapshots(server_events)
  snapshot = memory_payload(latest_memory_snapshot(server_events))
  reactivity = after["upkeep_reactivity"] || {}

  {
    "before_rss_mb" => before.dig("rss_mb"),
    "after_rss_mb" => after.dig("rss_mb"),
    "gc_count" => after.dig("gc", "gc_count"),
    "major_gc_count" => after.dig("gc", "major_gc_count"),
    "heap_live_slots" => after.dig("gc", "heap_live_slots"),
    "total_allocated_objects" => after.dig("gc", "total_allocated_objects"),
    "total_freed_objects" => after.dig("gc", "total_freed_objects"),
    "writes" => k6_metric(k6, "writes_issued", "count"),
    "observed" => k6_metric(k6, app_name == "upkeep" ? "deliveries_observed" : "refreshes_observed", "count"),
    "byte_equality_proofs" => proof_proven_delta(before, after, "byte_equality"),
    "p95_post_ms" => k6_metric(k6, "post_latency", "p(95)"),
    "p95_rtt_ms" => k6_metric(k6, "rtt", "p(95)"),
    "p95_suback_ms" => k6_metric(k6, "suback", "p(95)"),
    "rss" => rss,
    "process_rss" => process_rss_summary(rss_records),
    "rss_owners" => rss_owner_summary(rss_records),
    "memory_snapshot" => snapshot,
    "memory_phases" => phases,
    "phase_rss" => phase_rss_summary(phases, rss_records),
    "phase_deltas" => phase_deltas(phases),
    "retained_owner_deltas" => retained_owner_deltas(phases),
    "delivery_drain" => delivery_drain_summary(server_events, before, after),
    "reactivity" => reactivity
  }
end

def dispatch_memory_phases(results_dir, timestamp)
  path = File.join(results_dir, "dispatch-memory-#{timestamp}.jsonl")
  return {} unless File.exist?(path)

  load_jsonl(path).each_with_object({}) do |event, phases|
    phase = event["phase"].to_s
    next if phase.empty?
    phases[phase] = event
  end
end

report = {
  "timestamp" => timestamp,
  "puma_workers" => env_integer("PUMA_WORKERS"),
  "puma_threads" => env_integer("PUMA_THREADS"),
  "render_concurrency" => env_integer("UPKEEP_RENDER_CONCURRENCY"),
  "vus" => env_integer("BENCH_VUS"),
  "writes_per_vu" => env_integer("WRITES_PER_VU"),
  "upkeep" => app_summary(
    results_dir,
    timestamp,
    "upkeep",
    "after-memory-ceiling-upkeep",
    "memory-ceiling-shared-feed-churn-upkeep.json",
    "rss-#{timestamp}.jsonl"
  ),
  "turbo" => app_summary(
    results_dir,
    timestamp,
    "turbo",
    "after-memory-ceiling-turbo",
    "memory-ceiling-shared-feed-churn-turbo.json",
    "rss-turbo-#{timestamp}.jsonl"
  ),
  "dispatch" => {
    "memory_phases" => dispatch_memory_phases(results_dir, timestamp)
  }
}

json_path = File.join(results_dir, "memory-ceiling-shared-feed-churn-#{timestamp}.json")
md_path = File.join(results_dir, "memory-ceiling-shared-feed-churn-#{timestamp}.md")

File.write(json_path, JSON.pretty_generate(report))

def fmt(value)
  value.nil? ? "—" : value.to_s
end

def counts_table(counts)
  return "_No snapshot captured._\n" if counts.empty?

  counts.first(12).map { |name, count| "| `#{name}` | #{count} |" }.join("\n")
end

def phase_delta_table(deltas)
  return "_No phase deltas captured._\n" if deltas.empty?

  deltas.map do |delta|
    "| #{delta["from"]} -> #{delta["to"]} | #{delta["heap_live_slots"]} | #{delta["allocated_objects"]} | #{delta["gc_count"]} | #{delta["major_gc_count"]} |"
  end.join("\n")
end

def retained_owner_delta_table(deltas)
  return "_No retained owner deltas captured._\n" if deltas.empty?

  deltas.map do |delta|
    "| #{delta["from"]} -> #{delta["to"]} | `#{delta["name"]}` | #{delta["delta"]} |"
  end.join("\n")
end

def heap_allocator_delta_table(deltas)
  return "_No heap deltas captured._\n" if deltas.empty?

  deltas.map do |delta|
    "| #{delta["from"]} -> #{delta["to"]} | #{delta["heap_allocated_pages"]} | #{delta["heap_free_slots"]} | #{delta["old_objects"]} | #{delta["oldmalloc_increase_bytes"]} | #{delta["objectspace_memsize_bytes"]} |"
  end.join("\n")
end

def process_rss_table(report)
  rows = %w[upkeep turbo].flat_map do |app_key|
    app_label = app_key == "upkeep" ? "Upkeep" : "Turbo"
    roles = report.dig(app_key, "process_rss", "roles") || {}

    roles.sort.map do |role, summary|
      "| #{app_label} | `#{role}` | #{fmt(summary["peak_mb"])} | #{fmt(summary["avg_mb"])} | #{fmt(summary["max_processes"])} |"
    end
  end

  return "_No process RSS samples captured._\n" if rows.empty?

  rows.join("\n")
end

def rss_owner_table(report)
  owners = report.dig("upkeep", "rss_owners") || {}
  labels = {
    "request_workers" => "Request workers",
    "render_runtime" => "Render runtime"
  }

  rows = labels.filter_map do |key, label|
    summary = owners[key]
    next unless summary

    "| #{label} | #{fmt(summary["peak_mb"])} | #{fmt(summary["avg_mb"])} |"
  end

  return "_No RSS owner samples captured._\n" if rows.empty?

  rows.join("\n")
end

def phase_rss_table(report)
  phase_rss = report.dig("upkeep", "phase_rss") || {}
  rows = PHASE_ORDER.filter_map do |phase|
    summary = phase_rss[phase]
    next unless summary

    "| #{phase} | #{fmt(summary["request_workers_mb"])} | #{fmt(summary["render_runtime_mb"])} | #{fmt(summary["app_mb"])} | #{fmt(summary["combined_mb"])} |"
  end

  return "_No phase RSS samples captured._\n" if rows.empty?

  rows.join("\n")
end

def action_cable_residency_table(report)
  rows = %w[upkeep turbo].flat_map do |app_key|
    app_label = app_key == "upkeep" ? "Upkeep" : "Turbo"
    phases = report.dig(app_key, "memory_phases") || {}

    PHASE_ORDER.filter_map do |phase|
      counts = phases.dig(phase, "action_cable_counts") || {}
      next if counts.empty?

      "| #{app_label} | #{phase} | #{fmt(counts["ActionCable::Connection::Base"])} | #{fmt(counts["ActionCable::Channel::Base"])} | #{fmt(counts["Turbo::StreamsChannel"])} | #{fmt(counts["stream_registry.entries"])} |"
    end
  end

  return "_No Action Cable residency snapshots captured._\n" if rows.empty?

  rows.join("\n")
end

# M1 — Allocation / GC pressure delta per phase. Surfaces transient
# churn that retention-only RSS measurement hides.
def allocation_delta_table(phases)
  phases ||= {}
  rows = PHASE_ORDER.filter_map do |phase|
    delta = phases.dig(phase, "allocation_delta") || {}
    next if delta.empty? || delta["seed"]

    "| #{phase} | #{fmt(delta["since_phase"])} | #{fmt(delta["elapsed_s"])} | #{fmt(delta["allocated_objects"])} | #{fmt(delta["retained_objects"])} | #{fmt(delta["allocations_per_s"])} | #{fmt(delta["minor_gc_runs"])} | #{fmt(delta["major_gc_runs"])} | #{fmt(delta["gc_time_delta_ms"])} | #{fmt(delta["gc_time_share"])} |"
  end

  return "_No allocation deltas captured._\n" if rows.empty?

  rows.join("\n")
end

# M2 — Top retained classes by bytes. Populated only on phases where
# deep retention attribution was enabled (force_gc'd peak phases or
# when BENCH_CLASS_RETENTION=1 was set on the bench process).
#
# The "Δ bytes" / "Δ count" columns subtract the baseline `before`
# phase's reading for the same class, so workload growth is separated
# from framework baseline (Thread, RubyVM, Class, Module retention is
# present at boot regardless of workload). When a class only appears
# in the top-30 of a later phase, baseline columns show as 0 / "-",
# and the delta is the absolute reading.
# M4 — per-Upkeep-field retained bytes attribution. The store's
# `benchmark_retained_owner_counts` walker emits per-field totals
# (`store.fragment_locals_digests.bytes`, etc). This pivots the flat
# count Hash into a sorted-by-bytes table per phase, so the dominant
# retention owner is at the top.
SUBSCRIBER_FIELDS = %w[
  store.subscribers
  store.fragment_locals
  store.fragment_record_index
  store.fragment_bindings
  store.fragment_hashes
  store.fragment_locals_digests
  store.fragment_region_digests
  store.fragment_slot_states
  store.fragment_classifications
].freeze

def per_field_bytes_table(report)
  phases = report.dig("upkeep", "memory_phases") || {}
  rows = PHASE_ORDER.flat_map do |phase|
    counts = phases.dig(phase, "retained_owner_counts") || {}
    next [] if counts.empty?

    field_rows = SUBSCRIBER_FIELDS.filter_map do |field|
      bytes = counts["#{field}.bytes"]
      next nil if bytes.nil? || bytes.zero?

      {
        phase: phase,
        field: field,
        bytes: bytes,
        hashes: counts["#{field}.hashes"],
        entries: counts["#{field}.entries"],
        strings: counts["#{field}.strings"],
        string_bytes: counts["#{field}.string_bytes"]
      }
    end

    field_rows
      .sort_by { |row| -row[:bytes] }
      .map { |row| "| #{row[:phase]} | `#{row[:field]}` | #{fmt(row[:bytes])} | #{fmt(row[:hashes])} | #{fmt(row[:entries])} | #{fmt(row[:strings])} | #{fmt(row[:string_bytes])} |" }
  end

  return "_No per-field retained bytes captured._\n" if rows.empty?

  rows.join("\n")
end

def allocation_sites_table(phases)
  phases ||= {}
  rows = PHASE_ORDER.flat_map do |phase|
    sites = phases.dig(phase, "allocation_sites") || {}
    next [] if sites.empty?

    sites.flat_map do |cls, site_counts|
      site_counts.first(10).map do |site, count|
        "| `#{cls}` (#{phase}) | `#{site}` | #{fmt(count)} |"
      end
    end
  end

  return "_No allocation sites captured (set `BENCH_ALLOC_TRACE=1` on the bench process)._\n" if rows.empty?

  rows.join("\n")
end

def class_retention_table(phases)
  phases ||= {}
  baseline = phases.dig("before", "class_retention_bytes") || {}

  rows = PHASE_ORDER.flat_map do |phase|
    retention = phases.dig(phase, "class_retention_bytes") || {}
    next [] if retention.empty?

    retention.first(10).map do |cls, info|
      bytes = info.is_a?(Hash) ? info["bytes"] : info
      count = info.is_a?(Hash) ? info["count"] : nil

      base = baseline[cls]
      base_bytes = base.is_a?(Hash) ? base["bytes"].to_i : base.to_i
      base_count = base.is_a?(Hash) ? base["count"] : nil

      delta_bytes = bytes.to_i - base_bytes
      delta_count = count && base_count ? count - base_count : nil

      "| #{phase} | #{cls} | #{fmt(bytes)} | #{fmt(delta_bytes)} | #{fmt(count)} | #{fmt(delta_count)} |"
    end
  end

  return "_No class retention attribution captured (set BENCH_CLASS_RETENTION=1 or run a peak_post_gc phase)._\n" if rows.empty?

  rows.join("\n")
end

def delivery_drain_table(report)
  drain = report.dig("upkeep", "delivery_drain") || {}
  fanout_dur = drain["fanout_duration"] || {}
  per_conn = drain["per_connection_enqueue"] || {}

  [
    "| Serializations | #{fmt(drain["serializations_delta"])} | bytes packed | #{fmt(drain["bytes_total_delta"])} | avg #{fmt(drain["avg_payload_bytes"])} B |",
    "| Recipients | #{fmt(drain["recipients_delta"])} | sharing factor | #{fmt(drain["sharing_factor"])} | frames sent | #{fmt(drain["frames_sent_delta"])} |",
    "| Fanout p95 (s) | #{fmt(fanout_dur["p95_upper_bound_seconds"])} | sum (s) | #{fmt(fanout_dur["sum_seconds"])} | count | #{fmt(fanout_dur["count"])} |",
    "| Per-conn enqueue p95 (s) | #{fmt(per_conn["p95_upper_bound_seconds"])} | sum (s) | #{fmt(per_conn["sum_seconds"])} | count | #{fmt(per_conn["count"])} |",
    "| Supersession | inserted #{fmt(drain["supersession_inserted"])} | replaced #{fmt(drain["supersession_replaced"])} | unchanged #{fmt(drain["supersession_unchanged"])} | client acks #{fmt(drain["client_acks_delta"])} |",
    "| Health | render call errors | #{fmt(drain["render_call_errors_delta"])} | dropped frames | #{fmt(drain["frames_dropped_delta"])} |"
  ].join("\n")
end

def delivery_drain_admissibility(report)
  drain = report.dig("upkeep", "delivery_drain") || {}
  drain["admissible"] == false ? "non_admissible_render_readiness" : "admissible"
end

def reactivity_table(report)
  reactivity = report.dig("upkeep", "reactivity") || {}
  graph = reactivity["subscription_graphs"] || {}
  ambient = graph["ambient_replay_inputs"] || {}
  refused = reactivity["refused_boundaries"] || {}
  delivery = reactivity["delivery"] || {}
  live_deopts = delivery["live_deoptimizations"] || {}

  [
    "| Stored subscription graphs | #{fmt(graph["subscriptions"])} |",
    "| Frames | #{fmt(graph["frames"])} |",
    "| Dependencies | #{fmt(graph["dependencies"])} |",
    "| Replay recipes | #{fmt(graph["replay_recipes"])} |",
    "| Replay recipe bytes (total) | #{fmt(graph["replay_recipe_bytes_total"])} |",
    "| Replay recipe bytes (max) | #{fmt(graph["replay_recipe_bytes_max"])} |",
    "| Ambient replay inputs | #{fmt(ambient["total"])} |",
    "| Ambient replay inputs by source | #{fmt(ambient["by_source"])} |",
    "| Dependency sources | #{fmt(graph["dependency_sources"])} |",
    "| Refused boundaries | #{fmt(refused["total"])} |",
    "| Refused boundaries by reason | #{fmt(refused["by_reason"])} |",
    "| Live deoptimizations | #{fmt(live_deopts["total"])} |",
    "| Live deoptimizations by reason | #{fmt(live_deopts["by_reason"])} |",
    "| Runtime render groups | #{fmt(delivery["render_groups"])} |",
    "| Runtime render count | #{fmt(delivery["render_count"])} |"
  ].join("\n")
end

File.write(md_path, <<~MARKDOWN)
  # Memory Ceiling Shared Feed Churn

  Timestamp: `#{timestamp}`

  | App | Static app RSS MB | Peak app RSS MB | Peak combined RSS MB | Heap live slots | Allocated objects | Freed objects | GC | Major GC | Writes | Observed deliveries/refreshes | Byte-equality proofs | POST p95 ms |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | Upkeep | #{fmt(report.dig("upkeep", "rss", "static_app_mb"))} | #{fmt(report.dig("upkeep", "rss", "peak_app_mb"))} | #{fmt(report.dig("upkeep", "rss", "peak_combined_mb"))} | #{fmt(report.dig("upkeep", "heap_live_slots"))} | #{fmt(report.dig("upkeep", "total_allocated_objects"))} | #{fmt(report.dig("upkeep", "total_freed_objects"))} | #{fmt(report.dig("upkeep", "gc_count"))} | #{fmt(report.dig("upkeep", "major_gc_count"))} | #{fmt(report.dig("upkeep", "writes"))} | #{fmt(report.dig("upkeep", "observed"))} | #{fmt(report.dig("upkeep", "byte_equality_proofs"))} | #{fmt(report.dig("upkeep", "p95_post_ms"))} |
  | Turbo | #{fmt(report.dig("turbo", "rss", "static_app_mb"))} | #{fmt(report.dig("turbo", "rss", "peak_app_mb"))} | #{fmt(report.dig("turbo", "rss", "peak_combined_mb"))} | #{fmt(report.dig("turbo", "heap_live_slots"))} | #{fmt(report.dig("turbo", "total_allocated_objects"))} | #{fmt(report.dig("turbo", "total_freed_objects"))} | #{fmt(report.dig("turbo", "gc_count"))} | #{fmt(report.dig("turbo", "major_gc_count"))} | #{fmt(report.dig("turbo", "writes"))} | #{fmt(report.dig("turbo", "observed"))} | n/a | #{fmt(report.dig("turbo", "p95_post_ms"))} |

  ## Process RSS Breakdown

  | App | Role | Peak RSS MB | Avg RSS MB | Max processes |
  | --- | --- | ---: | ---: | ---: |
  #{process_rss_table(report)}

  ## Upkeep RSS Owners

  | Owner | Peak RSS MB | Avg RSS MB |
  | --- | ---: | ---: |
  #{rss_owner_table(report)}

  ## Upkeep Phase RSS

  | Phase | Request workers MB | Render runtime MB | App MB | Combined MB |
  | --- | ---: | ---: | ---: | ---: |
  #{phase_rss_table(report)}

  ## Upkeep Instance Counts

  | Class | Live instances |
  | --- | ---: |
  #{counts_table(report.dig("upkeep", "memory_snapshot", "upkeep_instance_counts") || {})}

  ## Upkeep Object Counts

  | Type | Count |
  | --- | ---: |
  #{counts_table(report.dig("upkeep", "memory_snapshot", "object_counts") || {})}

  ## Upkeep Retained Owner Counts

  | Owner | Count |
  | --- | ---: |
  #{counts_table(report.dig("upkeep", "memory_snapshot", "retained_owner_counts") || {})}

  ## Upkeep Phase Deltas

  | Phase | Heap live slots Δ | Allocated objects Δ | GC Δ | Major GC Δ |
  | --- | ---: | ---: | ---: | ---: |
  #{phase_delta_table(report.dig("upkeep", "phase_deltas") || [])}

  ## Ruby Heap And Allocator Deltas

  | Phase | Heap pages delta | Free slots delta | Old objects delta | Old malloc bytes delta | ObjectSpace bytes delta |
  | --- | ---: | ---: | ---: | ---: | ---: |
  #{heap_allocator_delta_table(report.dig("upkeep", "phase_deltas") || [])}

  ## Action Cable Residency

  | App | Phase | Connection objects | Channel objects | Turbo stream channels | Stream entries |
  | --- | --- | ---: | ---: | ---: | ---: |
  #{action_cable_residency_table(report)}

  ## Fanout Cost Attribution

  Dispatch delivery surface: `Envelope.encode_body(:client_delivery,
  payload)` packed once per render group, then `connection.enqueue(bytes)`
  on each recipient. The shared byte string is enqueued by reference.

  | Block | A | B | C | D | E |
  | --- | --- | ---: | --- | ---: | --- |
  #{delivery_drain_table(report)}

  Classification: `#{report.dig("upkeep", "delivery_drain", "classification")}`

  Admissibility: `#{delivery_drain_admissibility(report)}`

  Next optimization: `#{report.dig("upkeep", "delivery_drain", "next_optimization")}`

  ## Upkeep Reactivity Surface

  | Metric | Value |
  | --- | ---: |
  #{reactivity_table(report)}

  ## Upkeep Process — Allocation Pressure Per Phase

  | Phase | Since | Elapsed s | Allocated objs | Retained objs | Alloc/s | Minor GC | Major GC | GC time Δ ms | GC time share |
  | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  #{allocation_delta_table(report.dig("upkeep", "memory_phases"))}

  ## Upkeep Process — Top Retained Classes (deep walk)

  Δ columns subtract the `before` baseline so framework retention
  (Thread, RubyVM, Class, Module already present at boot) does not
  obscure workload-attributable growth. A candidate-promotion gate
  reads the Δ columns, not the absolutes.

  | Phase | Class | Bytes | Δ bytes | Count | Δ count |
  | --- | --- | ---: | ---: | ---: | ---: |
  #{class_retention_table(report.dig("upkeep", "memory_phases"))}

  ## Dispatch Runtime — Allocation Pressure Per Phase

  Phase markers come from the harness scraping the dispatch
  `/bench/memory?memory_phase=...` endpoint at upkeep phase
  boundaries. Empty when the dispatch endpoint was unreachable or the
  workload is not memory-ceiling-shaped.

  | Phase | Since | Elapsed s | Allocated objs | Retained objs | Alloc/s | Minor GC | Major GC | GC time Δ ms | GC time share |
  | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  #{allocation_delta_table(report.dig("dispatch", "memory_phases"))}

  ## Dispatch Runtime — Top Retained Classes (deep walk)

  | Phase | Class | Bytes | Δ bytes | Count | Δ count |
  | --- | --- | ---: | ---: | ---: | ---: |
  #{class_retention_table(report.dig("dispatch", "memory_phases"))}

  ## Largest Retained Owner Deltas

  | Phase | Owner | Count Δ |
  | --- | --- | ---: |
  #{retained_owner_delta_table(report.dig("upkeep", "retained_owner_deltas") || [])}

  ## Per-Field Retained Bytes (M4)

  Orders the subscription-store fields by retained bytes so the
  candidate-promotion question "which Upkeep field owns the dominant
  retention term?" reads directly off the table. M2 names the Ruby
  class (Hash, String); this names the Upkeep ownership.

  | Phase | Field | Bytes | Hashes | Entries | Strings | String bytes |
  | --- | --- | ---: | ---: | ---: | ---: | ---: |
  #{per_field_bytes_table(report)}

  ## Allocation Sites — Upkeep (M4, opt-in)

  Top file:line allocation sites for the top-3 retained classes
  (sampled up to 1,000 instances each). Populated only when
  `BENCH_ALLOC_TRACE=1` is set on the bench process.

  | Class | Site | Count |
  | --- | --- | ---: |
  #{allocation_sites_table(report.dig("upkeep", "memory_phases"))}

  ## Allocation Sites — Dispatch Runtime (M4, opt-in)

  | Class | Site | Count |
  | --- | --- | ---: |
  #{allocation_sites_table(report.dig("dispatch", "memory_phases"))}
MARKDOWN

puts "Memory ceiling report: #{md_path}"
