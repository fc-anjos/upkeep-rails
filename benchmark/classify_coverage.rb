#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "upkeep"

app_root = Pathname.new(ARGV[0] || "benchmark/upkeep-app").expand_path
app_views = app_root.join("app/views")
abort "app/views not found under #{app_root}" unless app_views.directory?

def partial_path(app_views, name)
  parts = name.split("/")
  parts[-1] = "_#{parts[-1]}" unless parts[-1].start_with?("_")
  candidates = [
    app_views.join("#{parts.join('/')}.html.erb"),
    app_views.join("#{parts.join('/')}.erb")
  ]
  candidates.find(&:file?)
end

partial_resolver = lambda do |name|
  path = partial_path(app_views, name)
  path&.read
end

templates = Dir.glob(app_views.join("**/*.erb")).map { |p| Pathname.new(p) }.sort

rows = templates.filter_map do |tmpl|
  rel = tmpl.relative_path_from(app_root).to_s
  next if rel.include?("/pwa/")
  next if rel.end_with?(".json.erb")

  source = tmpl.read
  identity = Upkeep::CompileTime::Analyze::IdentityReadClassifier.classify_source(
    source,
    partial_resolver: partial_resolver
  )
  render_mode = Upkeep::CompileTime::Analyze::RenderModeClassifier.classify_source(
    source,
    partial_resolver: partial_resolver
  )

  {
    path: rel,
    kind: tmpl.basename.to_s.start_with?("_") ? "partial" : "page",
    identity_tier: identity.classification,
    render_mode: render_mode.classification,
    reasons: render_mode.reasons.first(2)
  }
end

path_w = rows.map { |r| r[:path].length }.max

puts "== Fragment render-mode coverage dry-run =="
puts "App: #{app_root}"
puts
printf "%-#{path_w}s  %-8s  %-11s  %-18s  %s\n", "template", "kind", "tier", "render_mode", "why"
puts "-" * (path_w + 54)
rows.each do |row|
  why = row[:reasons].empty? ? "(clean)" : row[:reasons].join("; ")
  printf "%-#{path_w}s  %-8s  %-11s  %-18s  %s\n",
         row[:path], row[:kind], row[:identity_tier], row[:render_mode], why
end

puts
puts "== Summary =="
%w[partial page].each do |kind|
  subset = rows.select { |row| row[:kind] == kind }
  next if subset.empty?

  total = subset.size
  identity_counts = subset.group_by { |row| row[:identity_tier] }.transform_values(&:size)
  mode_counts = subset.group_by { |row| row[:render_mode] }.transform_values(&:size)
  printf "%-8s total=%d  none=%d  user-keyed=%d  unknown=%d  request_free=%d  synthetic_request=%d  page_replay=%d\n",
         "#{kind}s",
         total,
         identity_counts[:none].to_i,
         identity_counts[:user_keyed].to_i,
         identity_counts[:unknown].to_i,
         mode_counts[:request_free].to_i,
         mode_counts[:synthetic_request].to_i,
         mode_counts[:page_replay].to_i
end

puts
puts "Interpret the mode counts together with benchmark traffic. Compile-time coverage says what the analyzer can prove;"
puts "the benchmark reports show what the hot paths actually exercised at runtime."
