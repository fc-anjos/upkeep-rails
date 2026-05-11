# frozen_string_literal: true

require_relative "lib/upkeep/version"

Gem::Specification.new do |spec|
  spec.name = "upkeep-rails"
  spec.version = Upkeep::VERSION
  spec.authors = [ "Felipe Anjos" ]
  spec.email = [ "felipe@example.com" ]
  spec.license = "MIT"

  spec.summary = "Rails dogfood runtime for Upkeep reactive rendering"
  spec.description = "Rails dogfood runtime for deriving render dependency graphs from Rails rendering, data, and identity surfaces."
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir[
    "README.md",
    "lib/**/*.rb"
  ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "actionview", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "nokogiri", ">= 1.15"
  spec.add_dependency "railties", ">= 7.1"
end
