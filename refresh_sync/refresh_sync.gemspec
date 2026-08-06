require_relative "lib/refresh_sync/version"

Gem::Specification.new do |spec|
  spec.name = "refresh_sync"
  spec.version = RefreshSync::VERSION
  spec.authors = ["Upkeep"]
  spec.summary = "Automatic live-updating Rails pages: read sets from execution, Turbo 8 refresh as the sole correctness mechanism, region broadcast as a cost optimization."
  spec.description = <<~DESC
    RefreshSync records each page's read set from ActiveRecord execution
    (no SQL parsing, no view annotations), matches committed writes against
    it, and delivers debounced Turbo 8 page refreshes per cohort. Byte-shared
    surfaces earn scrubbed region broadcasts through runtime evidence.
    Identity fails closed; freshness fails open. Pure Ruby.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "turbo-rails", ">= 2.0", "< 3.0"
  # Provenance (region broadcast) render path. Pure-Ruby engine wrapper; herb
  # ships precompiled platform binaries, not a compile-on-install extension.
  spec.add_dependency "reactionview", ">= 0.3.0", "< 1.0"
  spec.add_dependency "herb", ">= 0.10.1", "< 0.11"
end
