# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "pathname"

module Upkeep
  class InstallGenerator < ::Rails::Generators::Base
    include ::Rails::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    def self.next_migration_number(dirname)
      ActiveRecord::Generators::Base.next_migration_number(dirname)
    end

    def create_subscription_migration
      return if migration_exists?("create_upkeep_subscriptions")

      @migration_version = ActiveRecord::Migration.current_version
      migration_template "create_upkeep_subscriptions.rb.erb", "db/migrate/create_upkeep_subscriptions.rb"
    end

    def create_initializer
      template "upkeep.rb", "config/initializers/upkeep.rb"
    end

    def create_browser_bootstrap
      template "subscription.js", "app/javascript/upkeep/subscription.js"
      append_application_import
      pin_action_cable
    end

    def mount_action_cable
      return if routes_path.exist? && routes_path.read.include?("ActionCable.server")

      route %(mount ActionCable.server => "/cable")
    end

    def show_identity_setup_guidance
      usages = detected_identity_usages
      return if usages.empty?

      say "\nIdentity setup required", :yellow
      say "Upkeep found request-side identity usage:"
      usages.each { |usage| say "  #{usage}" }
      say "Upkeep does not infer subscriber identity by naming convention."
      say "Add an explicit Upkeep::Rails.configure identity mapping in config/initializers/upkeep.rb."
      say "Pages that depend on undeclared non-absent CurrentAttributes or Warden identities are refused for live updates."
      say ""
    end

    private

    def migration_exists?(name)
      Dir.glob(destination_path("db/migrate/*.rb")).any? do |path|
        File.basename(path).include?(name)
      end
    end

    def append_application_import
      return unless application_js_path.exist?

      append_import("@hotwired/turbo-rails")
      append_import("upkeep/subscription")
    end

    def pin_action_cable
      return unless importmap_path.exist?

      pin_importmap("@hotwired/turbo-rails", "turbo.min.js")
      pin_importmap("@rails/actioncable", "actioncable.esm.js")
      pin_importmap("upkeep/subscription", "upkeep/subscription.js")
    end

    def append_import(specifier)
      return if application_js_path.read.include?(specifier)

      append_to_file application_js_path.to_s, %(import "#{specifier}"\n)
    end

    def pin_importmap(specifier, asset)
      return if importmap_path.read.include?(%("#{specifier}"))

      append_to_file importmap_path.to_s, %(pin "#{specifier}", to: "#{asset}"\n)
    end

    def detected_identity_usages
      usages = []
      source = application_source
      usages << "Current.user" if source.match?(/\bCurrent\.user\b/)
      usages << "session[:user_id]" if source.match?(/\bsession\[(?::user_id|['"]user_id['"])\]/)
      usages << "warden.user" if source.match?(/\bwarden\.user\b/)
      usages.uniq
    end

    def application_source
      app_paths.filter_map do |path|
        File.read(path)
      rescue StandardError
        nil
      end.join("\n")
    end

    def app_paths
      Dir.glob(destination_path("app/**/*")).select do |path|
        File.file?(path) && %w[.rb .erb].include?(File.extname(path))
      end
    end

    def routes_path
      Pathname(destination_path("config/routes.rb"))
    end

    def application_js_path
      Pathname(destination_path("app/javascript/application.js"))
    end

    def importmap_path
      Pathname(destination_path("config/importmap.rb"))
    end

    def destination_path(path)
      File.join(destination_root, path)
    end
  end
end
