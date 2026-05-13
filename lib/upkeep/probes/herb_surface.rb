# frozen_string_literal: true

require "json"
require "pathname"
require "time"
require_relative "../herb/template_manifest"

module Upkeep
  module Probes
  end
end

class Upkeep::Probes::HerbSurface
  HTML_ERB_PATTERN = "app/views/**/*.html.erb"

  PARSE_OPTIONS = Upkeep::HerbSupport::TemplateManifest::DEFAULT_PARSE_OPTIONS

  def initialize(project_root:)
    @project_root = Pathname(project_root)
    @workspace_root = @project_root
  end

  def run
    manifests = template_paths.map { |path| analyze_template(path) }

    {
      generated_at: Time.now.utc.iso8601,
      inputs: {
        benchmark_apps: benchmark_apps.map { |path| relative(path) },
        template_pattern: HTML_ERB_PATTERN,
        herb_options: PARSE_OPTIONS
      },
      summary: Upkeep::HerbSupport::TemplateManifest.summary(manifests),
      templates: manifests.map(&:to_h)
    }
  end

  private

  attr_reader :project_root, :workspace_root

  def benchmark_apps
    [
      project_root.join("benchmark/upkeep-app"),
      project_root.join("benchmark/turbo-app")
    ]
  end

  def template_paths
    benchmark_apps.flat_map { |app| app.glob(HTML_ERB_PATTERN) }.sort
  end

  def analyze_template(path)
    Upkeep::HerbSupport::TemplateManifest.build(
      path: relative(path),
      source: path.read,
      parse_options: PARSE_OPTIONS
    )
  end

  def relative(path)
    path.realpath.relative_path_from(workspace_root).to_s
  end
end
