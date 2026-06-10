# frozen_string_literal: true

require_relative "lib/upkeep/version"

Gem::Specification.new do |spec|
  spec.name = "upkeep-rails"
  spec.version = Upkeep::VERSION
  spec.authors = [ "Felipe dos Anjos" ]
  spec.email = [ "felipe.cavalheiro.anjos@gmail.com" ]
  spec.license = "MIT"

  spec.summary = "Dependency-tracked live updates for Rails views"
  spec.description = "Upkeep records the data and identity dependencies used while Rails renders a view, then updates subscribed frames when matching application data changes."
  spec.homepage = "https://github.com/fc-anjos/upkeep-rails"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{spec.version}"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  internal_files = Dir[
    "lib/upkeep/probes/**/*.rb",
    "lib/upkeep/proofs/**/*.rb"
  ] + %w[
    lib/upkeep/domain.rb
    lib/upkeep/herb/fallback_analyzer.rb
    lib/upkeep/herb/performance_gate.rb
    lib/upkeep/herb/runtime_alignment.rb
    lib/upkeep/proof_support.rb
    lib/upkeep/rendering.rb
    lib/upkeep/templates.rb
  ]

  spec.files = (Dir[
    "README.md",
    "docs/**/*.md",
    "LICENSE.txt",
    "upkeep-rails.gemspec",
    "lib/**/*.rb",
    "lib/generators/**/templates/**/*"
  ] - internal_files).sort
  spec.require_paths = [ "lib" ]

  spec.add_dependency "actionview", ">= 7.1", "< 9.0"
  spec.add_dependency "actionpack", ">= 7.1", "< 9.0"
  spec.add_dependency "actioncable", ">= 7.1", "< 9.0"
  spec.add_dependency "activerecord", ">= 7.1", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
  spec.add_dependency "herb", ">= 0.10.1", "< 0.11"
  spec.add_dependency "nokogiri", ">= 1.15", "< 2.0"
  spec.add_dependency "railties", ">= 7.1", "< 9.0"
  spec.add_dependency "turbo-rails", ">= 2.0", "< 3.0"
end
