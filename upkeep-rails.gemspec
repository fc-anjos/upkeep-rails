# frozen_string_literal: true

require_relative "lib/upkeep/version"

Gem::Specification.new do |spec|
  spec.name = "upkeep-rails"
  spec.version = Upkeep::VERSION
  spec.authors = [ "Felipe Anjos" ]
  spec.email = [ "felipe@example.com" ]
  spec.license = "MIT"

  spec.summary = "Rails runtime for Upkeep reactive rendering"
  spec.description = "Rails runtime for deriving render dependency graphs from Rails rendering, data, and identity surfaces."
  spec.required_ruby_version = ">= 3.2.0"

  internal_files = Dir[
    "lib/upkeep/probes/**/*.rb",
    "lib/upkeep/proofs/**/*.rb"
  ] + %w[
    lib/upkeep/domain.rb
    lib/upkeep/herb_loader.rb
    lib/upkeep/proof_support.rb
    lib/upkeep/rendering.rb
    lib/upkeep/templates.rb
  ]

  spec.files = (Dir[
    "README.md",
    "lib/**/*.rb",
    "lib/generators/**/templates/**/*"
  ] - internal_files).sort
  spec.require_paths = [ "lib" ]

  spec.add_dependency "actionview", ">= 7.1"
  spec.add_dependency "actioncable", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "nokogiri", ">= 1.15"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "turbo-rails", ">= 1.5"
end
