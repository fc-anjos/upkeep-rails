# frozen_string_literal: true

require "bundler"
require "rake/testtask"
require "rbconfig"

Rake::TestTask.new(:test) do |task|
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
