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
      :timings,
      :counters
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

      def call(controller, profile: false)
        timings = {}
        counters = {}
        action_result, recorder = measure(timings, :action_ms) do
          if profile
            profile_action(timings, counters) do
              Runtime::Observation.capture_request(profile: true) { yield }
            end
          else
            Runtime::Observation.capture_request { yield }
          end
        end
        timings.merge!(recorder.profile_timings)
        counters.merge!(recorder.profile_counts)
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
          timings,
          counters
        )
      end

      def profile_action(timings, counters)
        collector = ActionProfiler.new
        collector.capture { yield }.tap do
          timings.merge!(collector.timings)
          counters.merge!(collector.counters)
        end
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

      class ActionProfiler
        EVENT_MAP = {
          "sql.active_record" => :sql,
          "render_template.action_view" => :render_template,
          "render_partial.action_view" => :render_partial,
          "render_collection.action_view" => :render_collection
        }.freeze

        attr_reader :timings, :counters

        def initialize
          @thread = Thread.current
          @timings = Hash.new(0.0)
          @counters = Hash.new(0)
        end

        def capture
          callback = lambda do |name, started, finished, unique_id, payload|
            next unless Thread.current.equal?(@thread)

            event = ActiveSupport::Notifications::Event.new(name, started, finished, unique_id, payload)
            record(event)
          end

          ActiveSupport::Notifications.subscribed(callback, /\A(sql\.active_record|render_(template|partial|collection)\.action_view)\z/) do
            yield
          end
        ensure
          @timings.transform_values! { |value| value.round(3) }
        end

        private

        def record(event)
          key = EVENT_MAP[event.name]
          return unless key
          return if ignored_sql?(event)

          @timings[:"#{key}_ms"] += event.duration
          @counters[:"#{key}_count"] += 1
          @timings[:view_ms] += event.duration if event.name.end_with?(".action_view")
        end

        def ignored_sql?(event)
          event.name == "sql.active_record" && event.payload[:name] == "SCHEMA"
        end
      end
    end
  end
end
