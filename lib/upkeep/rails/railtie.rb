# frozen_string_literal: true

module Upkeep
  module Rails
    class Railtie < ::Rails::Railtie
      config.upkeep = ActiveSupport::OrderedOptions.new

      initializer "upkeep_rails.configure" do |app|
        Upkeep::Rails.configure do |config|
          config.enabled = app.config.upkeep.fetch(:enabled, true)
        end
      end

      initializer "upkeep_rails.install" do
        ActiveSupport.on_load(:active_record) { Upkeep::Rails::Install.call }
        ActiveSupport.on_load(:action_view) { Upkeep::Rails::Install.call }
      end
    end
  end
end
