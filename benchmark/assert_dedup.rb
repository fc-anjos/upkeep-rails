# frozen_string_literal: true

# Reads a benchmark matrix-compare-*.md or smoke-*.md summary and
# asserts dispatch is producing fragments + coalescing
# deliveries. Exits 0 on pass, 1 on regression. Designed to be called
# from bin/test after the matrix/pipeline_smoke workload so the whole
# end-to-end path (Puma cluster -> broker -> dispatch -> k6 client) is
# exercised.
#
# Regression thresholds are deliberately loose for the `smoke` tier
# (few VUs, few iterations). The point is to catch "zero", not to
# grade throughput — that's what the `gate` and `report` tiers are for.

# Only metrics in the "Dispatch Dedup (Upkeep only)"
# block — the comparison.md has several duplicated row labels (Total
# renders, Transmits) across sections, so we scope the parse to the
# dedup section where row identity is unambiguous.
THRESHOLDS = {
  "Render groups dispatched" => 1,
  "Subscriber-renders saved by dedup" => 0 # smoke has few overlaps; floor is "not negative"
}.freeze

# Rows whose delta must be exactly zero for the smoke gate to pass.
# `Classification downgrades` captures the atomic delivery gate
# forcing a `:none`/`:user-keyed` group down to `:unknown` — a
# structural correctness violation rather than a throughput regression,
# so any nonzero value fails the run.
MUST_BE_ZERO = %w[
  Client\ frames\ dropped\ (bridge\ missing)
  Client\ frames\ closed
  Client\ frames\ dropped\ (overflow)
  Delivery\ sids\ without\ payload
  Egress\ queue-full\ drops
  Egress\ overflow-closed\ connections
  Render\ call\ errors
  Classification\ downgrades
].freeze

path = ARGV[0] or abort("usage: ruby assert_dedup.rb <smoke-*.md | matrix-compare-*.md>")
abort("summary file not found: #{path}") unless File.exist?(path)

full = File.binread(path).force_encoding(Encoding::UTF_8)
body = full[/## Dispatch Dedup.*?(?=\n## |\z)/m] or abort("[assert_dedup] no 'Dispatch Dedup' section in #{path}")

def parse_metric(body, label)
  match = body.lines.find { |l| l.include?("| #{label} |") }
  return nil unless match

  cells = match.split("|").map(&:strip)
  raw = cells[2]
  return nil if raw.nil? || raw == "—" || raw.empty?
  raw.tr(" ", "").to_i
end

failures = []
THRESHOLDS.each do |label, min|
  value = parse_metric(body, label)
  if value.nil?
    failures << "#{label}: missing from summary"
  elsif value < min
    failures << "#{label}: #{value} < #{min}"
  end
end

MUST_BE_ZERO.each do |label|
  value = parse_metric(body, label)
  # Optional rows fail only when present and nonzero.
  failures << "#{label}: #{value} > 0" if value && value > 0
end

egress_frames_queued = parse_metric(body, "Egress frames queued")
egress_frames_drained = parse_metric(body, "Egress frames drained")
if egress_frames_queued && egress_frames_drained.nil?
  failures << "Egress frames drained: missing from summary"
elsif egress_frames_queued && egress_frames_drained < egress_frames_queued
  failures << "Egress frames drained: #{egress_frames_drained} < queued #{egress_frames_queued}"
end

ratio_line = body.lines.find { |l| l.include?("| Dedup ratio") }
ratio = ratio_line && ratio_line.split("|").map(&:strip).find { |c| c =~ /\A[\d.]+\z/ }&.to_f

if failures.empty?
  puts "[assert_dedup] OK  groups=#{parse_metric(body, "Render groups dispatched")} "\
       "saved=#{parse_metric(body, "Subscriber-renders saved by dedup")} "\
       "ratio=#{ratio || "n/a"}"
  exit 0
end

warn "[assert_dedup] REGRESSION in #{path}"
failures.each { |f| warn "  - #{f}" }
exit 1
