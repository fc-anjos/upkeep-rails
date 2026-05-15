# frozen_string_literal: true

require "active_support/concern"

module Upkeep
  module Rails
    module ControllerRuntime
      extend ActiveSupport::Concern

      SUPPRESS_KEY = :upkeep_rails_controller_runtime_suppressed

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

      def suppress
        previous = Thread.current[SUPPRESS_KEY]
        Thread.current[SUPPRESS_KEY] = true
        yield
      ensure
        Thread.current[SUPPRESS_KEY] = previous
      end

      def suppressed?
        Thread.current[SUPPRESS_KEY]
      end

      private

      def upkeep_capture_request(&action)
        return action.call if ControllerRuntime.suppressed?
        return action.call if Upkeep::Runtime::Observation.recorder

        Upkeep::Rails.deliver_changes_now!

        result = nil
        capture = nil
        _captured, changes = Upkeep::Runtime::ChangeLog.capture do
          if upkeep_subscription_request?
            capture = Upkeep::Capture::Request.call(self) { action.call }
            result = capture.action_result
          else
            result = action.call
          end
        end
        if capture && (registration = Upkeep::Rails.register_controller_subscription(self, capture))
          response.body = Upkeep::Rails::ClientSubscription.inject(
            capture.html,
            identity: registration.identity,
            subscription: registration.subscription
          )
        end
        Upkeep::Rails.deliver_changes!(changes)

        result
      end

      def upkeep_subscription_request?
        request.get? || request.head?
      end
    end
  end
end
