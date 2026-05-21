# frozen_string_literal: true

module Upkeep
  module Capture
    RequestSignature = Data.define(:controller, :action, :method, :fullpath)

    RequestResult = Data.define(
      :action_result,
      :html,
      :recorder,
      :response_status,
      :response_content_type,
      :response_media_type,
      :response_successful,
      :signature,
      :timings
    ) do
      def successful?
        !!response_successful
      end

      def html_response?
        response_media_type == "text/html" ||
          response_content_type.to_s.start_with?("text/html")
      end
    end

    module Request
      module_function

      def call(controller)
        timings = {}
        action_result, recorder = measure(timings, :action_ms) do
          Runtime::Observation.capture_request { yield }
        end
        html = measure(timings, :response_body_ms) { response_body_html(controller.response.body) }
        signature = measure(timings, :signature_ms) { signature_for(controller) }
        RequestResult.new(
          action_result,
          html,
          recorder,
          controller.response.status,
          controller.response.content_type,
          controller.response.media_type,
          controller.response.successful?,
          signature,
          timings
        )
      end

      def signature_for(controller)
        request = controller.request
        RequestSignature.new(
          controller.class.name,
          controller.action_name,
          request.request_method,
          request.fullpath
        )
      end

      def response_body_html(body)
        case body
        when String
          body
        when Array
          body.join
        else
          return body.body.join if body.respond_to?(:body) && body.body.respond_to?(:join)
          return body.to_a.join if body.respond_to?(:to_a)

          body.to_s
        end
      end

      def measure(timings, key)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        timings[key] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(3)
      end
    end
  end
end
