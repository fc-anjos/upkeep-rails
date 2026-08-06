require "rails/railtie"

module RefreshSync
  # Boot hooks (HANDOFF §7): read/write hooks on ActiveRecord, ambient
  # choke points, fragment-cache side entries, job-context registration
  # suppression, and the Turbo channel subscription observer. Provenance
  # (ReActionView/Herb compile path) is installed from the app initializer
  # because instrument/stamp paths are app configuration.
  class Railtie < ::Rails::Railtie
    initializer "refresh_sync.install" do
      ActiveSupport.on_load(:active_record) do
        RefreshSync.install!
      end
    end

    # Turbo::StreamsChannel is a zeitwerk autoload inside the turbo-rails
    # engine; attach the subscription observer once the app is fully booted.
    config.after_initialize do
      RefreshSync::Streams.attach! if defined?(::Turbo)
    end
  end
end
