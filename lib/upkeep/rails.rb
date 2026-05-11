# frozen_string_literal: true

require_relative "rails/configuration"
require_relative "rails/action_view_capture"
require_relative "rails/cable"
require_relative "rails/install"
require_relative "rails/railtie" if defined?(::Rails::Railtie)

module Upkeep
  module Rails
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def subscriptions
        @subscriptions ||= Subscriptions::Store.new
      end

      def transport
        @transport ||= Delivery::Transport.new
      end

      def reset_runtime!
        @subscriptions = Subscriptions::Store.new
        @transport = Delivery::Transport.new
      end
    end
  end
end
