#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

results_dir, timestamp, values, child_timestamps_arg, statuses_arg = ARGV
results_dir ||= File.expand_path("results", __dir__)
timestamp ||= Time.now.strftime("%Y%m%d%H%M%S")

concurrency_values = values.to_s.split(",")
child_timestamps = child_timestamps_arg.to_s.split
statuses = statuses_arg.to_s.split

runs = concurrency_values.each_with_index.map do |concurrency, index|
  child_timestamp = child_timestamps[index]
  report_path = File.join(results_dir, "render-dedup-isolated-#{child_timestamp}.json")
  report = File.exist?(report_path) ? JSON.parse(File.read(report_path)) : {}

  {
    "concurrency" => concurrency.to_i,
    "timestamp" => child_timestamp,
    "status" => statuses[index].to_i,
    "render_requests" => report["render_requests"],
    "deliveries" => report["deliveries"],
    "dedup_savings" => report["dedup_savings"],
    "ratio" => report["ratio"]
  }
rescue JSON::ParserError
  {
    "concurrency" => concurrency.to_i,
    "timestamp" => child_timestamp,
    "status" => statuses[index].to_i
  }
end

json_path = File.join(results_dir, "render-parallelism-sweep-#{timestamp}.json")
md_path = File.join(results_dir, "render-parallelism-sweep-#{timestamp}.md")

File.write(json_path, JSON.pretty_generate("timestamp" => timestamp, "runs" => runs))

rows = runs.map do |run|
  "| #{run["concurrency"]} | #{run["status"]} | #{run["render_requests"] || "—"} | #{run["deliveries"] || "—"} | #{run["dedup_savings"] || "—"} | #{run["ratio"] || "—"} |"
end.join("\n")

File.write(md_path, <<~MARKDOWN)
  # Render Parallelism Sweep

  Timestamp: `#{timestamp}`

  | UPKEEP_RENDER_CONCURRENCY | Exit | Render requests | Deliveries | Dedup savings | Ratio |
  | ---: | ---: | ---: | ---: | ---: | ---: |
  #{rows}
MARKDOWN

puts "Render parallelism sweep report: #{md_path}"
