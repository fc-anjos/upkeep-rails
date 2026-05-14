require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true
  config.cache_store = :memory_store
  config.public_file_server.enabled = true
  config.active_storage.service = :local if config.respond_to?(:active_storage)
  config.action_mailer.perform_caching = false
  config.i18n.fallbacks = true
  config.active_support.report_deprecations = false
  config.active_record.dump_schema_after_migration = false
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "warn")
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "lobsters-upkeep-benchmark-key")
  config.yjit = false if config.respond_to?(:yjit=)
end
