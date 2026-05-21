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

        payload = {
          controller: self.class.name,
          action: action_name,
          method: request.request_method,
          path: request.fullpath,
          subscription_request: upkeep_subscription_request?
        }
        ActiveSupport::Notifications.instrument(Upkeep::Rails::REQUEST_CAPTURE, payload) do
          upkeep_capture_request_with_timing(action, payload)
        end
      end

      def upkeep_capture_request_with_timing(action, payload)
        measure_phase(payload, :deliver_pending_ms) { Upkeep::Rails.deliver_changes_now! }

        result = nil
        capture = nil
        changes = []
        measure_phase(payload, :change_capture_ms) do
          _captured, changes = Upkeep::Runtime::ChangeLog.capture do
            if payload.fetch(:subscription_request)
              capture = Upkeep::Capture::Request.call(self, profile: request_capture_profile?) { action.call }
              result = capture.action_result
            else
              measure_phase(payload, :action_ms) { result = action.call }
            end
          end
        end
        record_capture_payload(payload, capture) if capture

        registration = nil
        if capture
          measure_phase(payload, :register_ms) do
            registration = Upkeep::Rails.register_controller_subscription(self, capture)
          end
        end
        payload[:registered] = !!registration
        if capture && registration
          measure_phase(payload, :inject_ms) do
            response.body = Upkeep::Rails::ClientSubscription.inject(
              capture.html,
              identity: registration.identity,
              subscription: registration.subscription
            )
          end
          payload[:subscription_id] = registration.subscription.id
        end
        measure_phase(payload, :deliver_changes_ms) { Upkeep::Rails.deliver_changes!(changes) }

        result
      end

      def record_capture_payload(payload, capture)
        payload[:response_status] = capture.response_status
        payload[:response_content_type] = capture.response_content_type
        payload[:response_media_type] = capture.response_media_type
        payload[:html_response] = capture.html_response?
        payload[:response_successful] = capture.successful?
        payload[:html_bytes] = capture.html.bytesize
        payload[:graph_frames] = capture.recorder.graph.frame_nodes.size
        payload[:graph_dependencies] = capture.recorder.graph.dependency_nodes.size
        capture.timings.each do |phase, ms|
          payload[:"capture_#{phase}"] = ms
        end
        capture.counters.each do |counter, value|
          payload[:"capture_#{counter}"] = value
        end
      end

      def measure_phase(payload, key)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        payload[key] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(3)
      end

      def upkeep_subscription_request?
        request.get? || request.head?
      end

      def request_capture_profile?
        ActiveSupport::Notifications.notifier.listening?(Upkeep::Rails::REQUEST_CAPTURE)
      end
    end
  end
end
