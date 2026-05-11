# frozen_string_literal: true

require "active_support/concern"

module Upkeep
  module Rails
    module ControllerRuntime
      extend ActiveSupport::Concern

      included do
        prepend_around_action :upkeep_capture_request
      end

      module_function

      def install
        return if @installed
        return unless defined?(::ActionController::Base)

        ::ActionController::Base.include(self)
        @installed = true
      end

      def installed?
        !!@installed
      end

      def reset!
        @installed = false
      end

      private

      def upkeep_capture_request(&action)
        return action.call if Upkeep::Runtime::Observation.recorder

        Upkeep::Rails.deliver_changes_now!

        captured, changes = Upkeep::Runtime::ChangeLog.capture do
          Upkeep::Runtime::Observation.capture_request { action.call }
        end
        result, recorder = captured
        Upkeep::Rails.register_controller_subscription(self, recorder)
        Upkeep::Rails.deliver_changes!(changes)

        result
      end
    end
  end
end
