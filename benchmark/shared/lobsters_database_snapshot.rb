# frozen_string_literal: true

require "fileutils"

module LobstersDatabaseSnapshot
  module_function

  def snapshot_path(app_dir)
    File.join(app_dir, "storage", "benchmark-seed.sqlite3")
  end

  def run_path(app_dir, timestamp:, variant:)
    File.join(app_dir, "storage", "benchmark-#{variant}-#{timestamp}.sqlite3")
  end

  def ensure_snapshot!(app_dir:, bundle_gemfile:, env:)
    path = snapshot_path(app_dir)
    return path if File.exist?(path) && !ENV["LOBSTERS_REBUILD_SEED"] && !snapshot_stale?(path)

    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.rm_f(path)

    system(
      env.merge(
        "BUNDLE_GEMFILE" => bundle_gemfile,
        "RAILS_ENV" => "benchmark",
        "UPKEEP_LOBSTERS_DATABASE" => path,
        "TURBO_LOBSTERS_DATABASE" => path
      ),
      "bundle", "exec", "bin/rails", "db:schema:load", "db:seed",
      chdir: app_dir,
      exception: true
    )

    path
  end

  def snapshot_stale?(path)
    seed_path = File.expand_path("lobsters_seed_data.rb", __dir__)
    File.mtime(path) < File.mtime(seed_path)
  end

  def copy_for_run!(app_dir:, timestamp:, variant:)
    source = snapshot_path(app_dir)
    raise "missing Lobsters seed snapshot: #{source}" unless File.exist?(source)

    target = run_path(app_dir, timestamp: timestamp, variant: variant)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
    target
  end
end
