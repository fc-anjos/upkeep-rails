# frozen_string_literal: true

require "bundler"
require "bundler/gem_tasks"
require "fileutils"
require "rake/testtask"
require "rbconfig"
require_relative "lib/upkeep/version"

namespace :native do
  desc "Build Upkeep's SQLGlot library for the current platform"
  task :build do
    ruby File.expand_path("ext/sqlglot_rust/extconf.rb", __dir__)
  end

  desc "Build a platform-specific upkeep-rails gem"
  task package: :build do
    platform = ENV.fetch("PLATFORM") do
      Gem::Platform.local.to_s.sub(/-\d+\z/, "")
    end
    output = File.expand_path(
      "pkg/upkeep-rails-#{Upkeep::VERSION}-#{platform}.gem",
      __dir__
    )
    FileUtils.mkdir_p(File.dirname(output))

    sh(
      {"UPKEEP_NATIVE_PLATFORM" => platform},
      RbConfig.ruby,
      "-S",
      "gem",
      "build",
      "upkeep-rails.gemspec",
      "--output",
      output
    )
  end
end

Rake::TestTask.new(test: "native:build") do |task|
  task.libs << "test"
  task.libs << "lib"
  task.test_files = FileList["test/**/*_test.rb"]
end

namespace :test do
  task :benchmark_apps do
    %w[
      benchmark/upkeep-app
      benchmark/turbo-app
    ].each { |app_path| run_benchmark_app_tests(app_path) }
  end
end

task proof: [ :test, "test:benchmark_apps" ] do
  ruby "bin/run"
end

task default: :proof

def run_benchmark_app_tests(app_path)
  ruby = RbConfig.ruby
  env = {
    "BENCH" => nil,
    "BUNDLE_GEMFILE" => "Gemfile",
    "PATH" => "#{File.dirname(ruby)}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH", "")}",
    "RAILS_ENV" => "test"
  }

  Bundler.with_unbundled_env do
    sh(
      env,
      ruby,
      "-S",
      "bundle",
      "exec",
      ruby,
      "bin/rails",
      "db:test:prepare",
      "test",
      chdir: app_path
    )
  end
end
