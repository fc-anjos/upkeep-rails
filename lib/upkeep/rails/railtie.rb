# frozen_string_literal: true

module Upkeep
  module Rails
    class Railtie < ::Rails::Railtie
      config.upkeep = ActiveSupport::OrderedOptions.new

      initializer "upkeep_rails.configure" do |app|
        Upkeep::Rails.configure do |config|
          config.enabled = app.config.upkeep.fetch(:enabled, true)
          config.subscription_store = app.config.upkeep.fetch(:subscription_store, config.subscription_store)
          config.delivery_adapter = app.config.upkeep.fetch(:delivery_adapter, Railtie.default_delivery_adapter(app))
          config.delivery_queue = app.config.upkeep.fetch(:delivery_queue, config.delivery_queue)
          config.delivery_batch_window =
            app.config.upkeep.fetch(:delivery_batch_window, config.delivery_batch_window)
          config.activation_token_expires_in =
            app.config.upkeep.fetch(:activation_token_expires_in, config.activation_token_expires_in)
          config.refused_boundary_behavior =
            app.config.upkeep.fetch(:refused_boundary_behavior, config.refused_boundary_behavior)
        end
      end

      initializer "upkeep_rails.install" do
        ActiveSupport.on_load(:active_record) { Upkeep::Rails::Install.call }
        ActiveSupport.on_load(:action_controller_base) { Upkeep::Rails::Install.call }
        ActiveSupport.on_load(:action_view) { Upkeep::Rails::Install.call }
      end

      initializer "upkeep_rails.validate_configuration", after: "upkeep_rails.install" do |app|
        app.config.after_initialize do
          Upkeep::Rails.validate_configuration! unless Railtie.rake_task?
        end
      end

      def self.rake_task?
        defined?(::Rake) &&
          ::Rake.respond_to?(:application) &&
          ::Rake.application.top_level_tasks.any?
      end

      def self.default_delivery_adapter(app)
        if app.respond_to?(:env) && app.env.to_s == "production"
          :active_job
        else
          Upkeep::Rails.configuration.delivery_adapter
        end
      end
    end
  end
end
