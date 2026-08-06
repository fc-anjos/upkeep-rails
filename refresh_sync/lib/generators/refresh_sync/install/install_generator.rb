require "rails/generators"
require "rails/generators/active_record"

module RefreshSync
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "initializer.rb", "config/initializers/refresh_sync.rb"
      end

      def copy_migration
        migration_template "create_refresh_sync_tables.rb",
                           "db/migrate/create_refresh_sync_tables.rb"
      end

      def copy_herb_config
        # ReActionView/Herb provenance needs prism_nodes so compile-time
        # visitors can self-serve template identity (spike/FINDINGS.md §2).
        template "herb.yml", ".herb.yml" unless File.exist?(File.join(destination_root, ".herb.yml"))
      end
    end
  end
end
