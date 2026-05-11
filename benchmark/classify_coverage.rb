#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "upkeep"

project_root = Pathname.new(ARGV[0] || ".").expand_path
abort "benchmark apps not found under #{project_root}" unless project_root.join("benchmark/upkeep-app").directory?

report = Upkeep::Probes::HerbSurface.new(project_root: project_root).run
templates = report.fetch(:templates)
path_width = templates.map { |row| row.fetch(:path).length }.max || 8

puts "== Herb benchmark surface coverage =="
puts "Project: #{project_root}"
puts
printf "%-#{path_width}s  %-5s  %7s  %7s  %7s  %s\n", "template", "parse", "renders", "helpers", "targets", "root"
puts "-" * (path_width + 48)

templates.each do |row|
  root = row.fetch(:root_shape)
  root_label = if root.fetch(:single_root, false)
    "single"
  elsif root.fetch(:multi_root, false)
    "multi"
  else
    "none"
  end

  printf "%-#{path_width}s  %-5s  %7d  %7d  %7d  %s\n",
    row.fetch(:path),
    row.fetch(:parse).fetch(:ok) ? "ok" : "fail",
    row.fetch(:render_nodes).size,
    row.fetch(:helper_lowered_elements).size,
    row.fetch(:frontend_tag_plan).size,
    root_label
end

puts
puts JSON.pretty_generate(report.fetch(:summary))
