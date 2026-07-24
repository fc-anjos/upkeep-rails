# frozen_string_literal: true

require_relative "lib/sqlglot/semantics/version"

Gem::Specification.new do |spec|
  spec.name = "sqlglot-semantics"
  spec.version = Sqlglot::Semantics::VERSION
  spec.authors = ["Felipe dos Anjos"]
  spec.email = ["felipe.cavalheiro.anjos@gmail.com"]
  spec.license = "MIT"

  spec.summary = "Semantic SQLGlot bindings for Ruby"
  spec.description = "A sibling extension for the SQLGlot Ruby gem that exposes the established sql-glot-rust schema, qualification, scope, and lineage APIs."
  spec.homepage = "https://github.com/fc-anjos/upkeep-rails"
  spec.required_ruby_version = ">= 3.2.0"

  native_platform = ENV["SQLGLOT_SEMANTICS_PLATFORM"]
  spec.files = Dir.chdir(__dir__) do
    Dir[
      "lib/**/*.rb",
      "ext/sqlglot_semantics/{Cargo.toml,Cargo.lock,extconf.rb,src/**/*.rs}",
      "Gemfile",
      "LICENSE.txt",
      "Rakefile",
      "README.md",
      "sqlglot-semantics.gemspec",
      "test/**/*_test.rb"
    ]
  end
  spec.require_paths = ["lib"]

  if native_platform
    native_libraries = Dir.chdir(__dir__) do
      Dir["lib/sqlglot/semantics/libsqlglot_semantics.{so,dylib,dll}"]
    end
    raise "native library is required for platform gem #{native_platform}" if native_libraries.empty?

    spec.platform = native_platform
    spec.files.concat(native_libraries)
  else
    spec.extensions = ["ext/sqlglot_semantics/extconf.rb"]
  end

  spec.add_dependency "ffi", "~> 1.15"
  spec.add_dependency "sqlglot", "= 0.1.1"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true",
    "sqlglot_rust_version" => "0.10.12"
  }
end
