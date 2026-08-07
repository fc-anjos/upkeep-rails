require "rails/railtie"

module Upkeep
  # Boot hooks (HANDOFF §7): read/write hooks on ActiveRecord, ambient
  # choke points, fragment-cache side entries, job-context registration
  # suppression, and the Turbo channel subscription observer. Provenance
  # (ReActionView/Herb compile path) is installed from the app initializer
  # because instrument/stamp paths are app configuration.
  class Railtie < ::Rails::Railtie
    initializer "upkeep.install" do
      ActiveSupport.on_load(:active_record) do
        Upkeep.install!
      end
    end

    rake_tasks do
      load File.expand_path("tasks/report.rake", __dir__)
    end

    # Turbo::StreamsChannel is a zeitwerk autoload inside the turbo-rails
    # engine; attach the subscription observer once the app is fully booted.
    config.after_initialize do
      Upkeep::Streams.attach! if defined?(::Turbo)
      Upkeep::Health.check_cable_topology!
    end
  end
end
