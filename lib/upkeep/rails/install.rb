# frozen_string_literal: true

module Upkeep
  module Rails
    module Install
      module_function

      def call
        return unless Upkeep::Rails.configuration.enabled
        return if @installed

        Runtime::Install.call if defined?(::ActiveRecord::Base)
        ActionViewCapture.install if defined?(::ActionView::Template)

        @installed = true
      end

      def installed?
        !!@installed
      end

      def reset!
        @installed = false
      end
    end
  end
end
