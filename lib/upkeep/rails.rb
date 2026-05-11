# frozen_string_literal: true

require_relative "rails/configuration"
require_relative "rails/action_view_capture"
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
    end
  end
end
