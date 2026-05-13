# frozen_string_literal: true

module Upkeep
  module Rails
    class Railtie < ::Rails::Railtie
      config.upkeep = ActiveSupport::OrderedOptions.new

      initializer "upkeep_rails.configure" do |app|
        Upkeep::Rails.configure do |config|
          config.enabled = app.config.upkeep.fetch(:enabled, true)
          config.subscription_store = app.config.upkeep.fetch(:subscription_store, config.subscription_store)
        end
      end

      initializer "upkeep_rails.install" do
        ActiveSupport.on_load(:active_record) { Upkeep::Rails::Install.call }
        ActiveSupport.on_load(:action_controller_base) { Upkeep::Rails::Install.call }
        ActiveSupport.on_load(:action_view) { Upkeep::Rails::Install.call }
      end

      initializer "upkeep_rails.validate_configuration", after: "upkeep_rails.install" do |app|
        app.config.after_initialize do
          Upkeep::Rails.validate_configuration!(environment: app.env) unless Railtie.rake_task?
        end
      end

      def self.rake_task?
        defined?(::Rake) &&
          ::Rake.respond_to?(:application) &&
          ::Rake.application.top_level_tasks.any?
      end
    end
  end
end
