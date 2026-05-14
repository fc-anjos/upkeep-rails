# frozen_string_literal: true

require "fileutils"
require_relative "lobsters_database_snapshot"

variant = ARGV.fetch(0)
app_dir = Dir.pwd
database_key = "#{variant.upcase}_LOBSTERS_DATABASE"

LobstersDatabaseSnapshot.ensure_snapshot!(
  app_dir: app_dir,
  bundle_gemfile: File.join(app_dir, "Gemfile"),
  env: {
    "SECRET_KEY_BASE" => ENV.fetch("SECRET_KEY_BASE"),
    "NUM_USERS" => ENV.fetch("NUM_USERS", "50"),
    database_key => ENV.fetch(database_key)
  }
)

FileUtils.cp(
  LobstersDatabaseSnapshot.snapshot_path(app_dir),
  ENV.fetch(database_key)
)
