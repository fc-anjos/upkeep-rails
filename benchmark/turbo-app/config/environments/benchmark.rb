require "active_support/core_ext/integer/time"

# Benchmark environment: production-like reload/eager-load semantics, dev-like
# access (plain HTTP, local errors). The default `development` env serializes
# `RoutingError` under concurrent load because `enable_reloading = true` lets
# the reloader race with in-flight requests. Disabling reloading eliminates
# that race without taking on production's SSL/log requirements.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true

  config.consider_all_requests_local = true
  config.server_timing = false

  config.action_controller.perform_caching = false
  config.cache_store = :memory_store

  config.active_support.deprecation = :log
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = false
  config.active_record.query_log_tags_enabled = false

  # Benchmark runs invoke `db:migrate` against the benchmark sqlite
  # database; without this, each run rewrites `db/schema.rb` to disk,
  # dirtying the working tree and breaking `git checkout` between
  # commits during bisects. The benchmark schema is owned by the
  # migrations + the prepared sqlite snapshot, not by the tracked
  # `schema.rb`, so the dump is never the source of truth here.
  config.active_record.dump_schema_after_migration = false
  config.active_job.verbose_enqueue_logs = false
  config.action_dispatch.verbose_redirect_logs = false
  config.assets.quiet = true

  config.action_controller.raise_on_missing_callback_actions = true

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
end
