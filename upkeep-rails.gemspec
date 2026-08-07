require_relative "lib/upkeep/version"

Gem::Specification.new do |spec|
  spec.name = "upkeep-rails"
  spec.version = Upkeep::VERSION
  spec.authors = ["Felipe dos Anjos"]
  spec.homepage = "https://github.com/fc-anjos/upkeep-rails"
  spec.summary = "Automatic live-updating Rails pages: read sets from execution, Turbo 8 refresh as the sole correctness mechanism, region broadcast as a cost optimization."
  spec.description = <<~DESC
    Upkeep records each page's read set from ActiveRecord execution
    (no SQL parsing, no view annotations), matches committed writes against
    it, and delivers debounced Turbo 8 page refreshes per cohort. Byte-shared
    surfaces earn scrubbed region broadcasts through runtime evidence.
    Identity fails closed; freshness fails open. Pure Ruby.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "ext/sqlglot_rust/extconf.rb", "README.md"]
  spec.require_paths = ["lib"]

  # SQLGlot native parser: packaged binary on platform gems, source build
  # (git + cargo) everywhere else.
  native_platform = ENV["UPKEEP_NATIVE_PLATFORM"]
  if native_platform
    native_libraries = Dir["lib/upkeep/sqlglot/{lib,}sqlglot_rust.{so,dylib,dll}"]
    raise "native library is required for platform gem #{native_platform}" if native_libraries.empty?

    spec.platform = native_platform
    spec.files += native_libraries
  else
    spec.extensions = ["ext/sqlglot_rust/extconf.rb"]
  end

  spec.add_dependency "ffi", ">= 1.15", "< 2.0"
  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "turbo-rails", ">= 2.0", "< 3.0"
  # Provenance (region broadcast) render path. Pure-Ruby engine wrapper; herb
  # ships precompiled platform binaries, not a compile-on-install extension.
  spec.add_dependency "reactionview", ">= 0.3.0", "< 1.0"
  spec.add_dependency "herb", ">= 0.10.1", "< 0.11"
end
