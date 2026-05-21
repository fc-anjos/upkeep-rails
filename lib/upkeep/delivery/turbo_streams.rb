# frozen_string_literal: true

require "active_support/notifications"
require "cgi"

module Upkeep
  module Delivery
    class TurboStreams
      DELIVERY_ERROR = "delivery_error.upkeep"

      Stream = Data.define(
        :action,
        :target,
        :target_selector,
        :html,
        :html_digest,
        :identity_signature,
        :shared_stream_name,
        :subscriber_ids,
        :matched_dependency_keys,
        :deoptimization_reason,
        :render_duration_ms
      ) do
        def to_html
          attributes = %(action="#{CGI.escapeHTML(action)}" targets="#{CGI.escapeHTML(target_selector)}")
          return %(<turbo-stream #{attributes}></turbo-stream>) if action == "remove"

          %(<turbo-stream #{attributes}><template>#{html}</template></turbo-stream>)
        end

        def rendered?
          action != "remove"
        end

        def for_subscriber?(subscriber_id)
          subscriber_ids.include?(subscriber_id)
        end

        def report
          {
            action: action,
            target: target.to_h,
            target_selector: target_selector,
            identity_signature: identity_signature,
            shared_stream_name: shared_stream_name,
            html_digest: html_digest,
            subscriber_ids: subscriber_ids,
            matched_dependency_keys: matched_dependency_keys,
            deoptimization_reason: deoptimization_reason,
            render_duration_ms: render_duration_ms
          }
        end
      end

      Envelope = Data.define(:subscriber_id, :streams, :stream_name) do
        def self.subscriber(subscriber_id, streams)
          new(subscriber_id, streams, nil)
        end

        def self.shared(stream_name, streams)
          new("shared:#{stream_name}", streams, stream_name)
        end

        def body
          streams.map(&:to_html).join("\n")
        end

        def report
          {
            subscriber_id: subscriber_id,
            streams: streams.map(&:report)
          }
        end
      end

      Batch = Data.define(:streams) do
        def envelopes
          return [] if streams.empty?

          direct_subscriber_id = single_direct_subscriber_id
          return [Envelope.subscriber(direct_subscriber_id, streams)] if direct_subscriber_id

          shared_envelopes + subscriber_envelopes
        end

        def envelope_for(subscriber_id)
          Envelope.subscriber(subscriber_id, streams.select { |stream| stream.for_subscriber?(subscriber_id) })
        end

        def report
          {
            streams: streams.map(&:report),
            envelopes: envelopes.map(&:report)
          }
        end

        private

        def single_direct_subscriber_id
          return if streams.any?(&:shared_stream_name)

          subscriber_ids = streams.flat_map(&:subscriber_ids).uniq
          subscriber_ids.first if subscriber_ids.one?
        end

        def shared_envelopes
          streams
            .select(&:shared_stream_name)
            .group_by(&:shared_stream_name)
            .map { |stream_name, shared_streams| Envelope.shared(stream_name, shared_streams) }
        end

        def subscriber_envelopes
          direct_streams = streams.reject(&:shared_stream_name)
          direct_streams
            .flat_map(&:subscriber_ids)
            .uniq
            .sort_by(&:to_s)
            .map { |subscriber_id| Envelope.subscriber(subscriber_id, direct_streams.select { |stream| stream.for_subscriber?(subscriber_id) }) }
        end
      end

      def build(plan)
        build_many([plan])
      end

      def build_many(plans)
        payload = {
          plans: plans.size,
          planned_targets: plans.sum { |plan| plan.targets.size }
        }

        ActiveSupport::Notifications.instrument("build_turbo_streams.upkeep", payload) do
          streams = plans.flat_map { |plan| stream_targets(plan.targets) }.compact
          batch = Batch.new(merge_streams(streams))
          payload.merge!(payload_for(batch, rendered_streams: streams))
          batch
        end
      end

      private

      def payload_for(batch, rendered_streams:)
        envelopes = batch.envelopes

        {
          streams: batch.streams.size,
          envelopes: envelopes.size,
          actions: batch.streams.map(&:action).tally,
          deoptimizations: batch.streams.filter_map(&:deoptimization_reason).tally,
          renders: rendered_streams.count(&:rendered?),
          render_duration_ms: sum_render_duration(rendered_streams),
          payload_bytes: envelopes.sum { |envelope| envelope.body.bytesize }
        }
      end

      def stream_targets(planned_targets)
        return [] if planned_targets.empty?
        return [stream_for(planned_targets.first)] if planned_targets.one?

        planned_targets.group_by { |planned_target| render_group_key(planned_target) }.map do |_key, targets|
          stream_for(
            targets.first,
            subscriber_ids: targets.flat_map(&:subscriber_ids),
            matched_dependency_keys: targets.flat_map(&:matched_dependency_keys)
          )
        end
      end

      # The write that produced these changes has already committed; an isolated render/targeting
      # failure for one target must never propagate back into the writer's request. Rescue per
      # target, surface the failure via instrumentation, and keep delivering the other targets.
      def stream_for(planned_target, subscriber_ids: planned_target.subscriber_ids, matched_dependency_keys: planned_target.matched_dependency_keys)
        build_stream(planned_target, subscriber_ids: subscriber_ids, matched_dependency_keys: matched_dependency_keys)
      rescue StandardError => error
        ActiveSupport::Notifications.instrument(
          DELIVERY_ERROR,
          target: planned_target.target.to_h,
          action: planned_target.action,
          subscription_id: planned_target.subscription_id,
          subscriber_ids: subscriber_ids.uniq.sort_by(&:to_s),
          error_class: error.class.name,
          error_message: error.message
        )
        nil
      end

      def build_stream(planned_target, subscriber_ids:, matched_dependency_keys:)
        html, render_duration_ms = render_target(planned_target)

        Stream.new(
          planned_target.action,
          planned_target.target,
          target_selector_for(planned_target.target),
          html,
          Targeting::Extraction.digest_html(html),
          planned_target.identity_signature,
          shared_stream_name_for(planned_target, subscriber_ids: subscriber_ids),
          subscriber_ids.uniq.sort_by(&:to_s),
          matched_dependency_keys.uniq,
          planned_target.deoptimization_reason,
          render_duration_ms
        )
      end

      def render_target(planned_target)
        return ["", 0.0] if planned_target.action == "remove"

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        html = planned_target.render
        finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [html, ((finished_at - started_at) * 1000.0).round(3)]
      end

      def render_group_key(planned_target)
        [
          planned_target.action,
          planned_target.target.kind,
          planned_target.target.id,
          planned_target.identity_signature,
          planned_target.sharing_signature,
          SharedStreams.signature_for(planned_target.recipe),
          planned_target.deoptimization_reason
        ]
      end

      def merge_streams(streams)
        streams.each_with_object({}) do |stream, indexed_streams|
          key = [
            stream.action,
            stream.target.kind,
            stream.target.id,
            stream.identity_signature,
            stream.shared_stream_name,
            stream.html_digest,
            stream.deoptimization_reason
          ]
          indexed_streams[key] = merge_stream(indexed_streams[key], stream)
        end.values
      end

      def merge_stream(existing, stream)
        return stream unless existing

        Stream.new(
          existing.action,
          existing.target,
          existing.target_selector,
          existing.html,
          existing.html_digest,
          existing.identity_signature,
          existing.shared_stream_name,
          (existing.subscriber_ids + stream.subscriber_ids).uniq.sort_by(&:to_s),
          (existing.matched_dependency_keys + stream.matched_dependency_keys).uniq,
          existing.deoptimization_reason,
          (existing.render_duration_ms + stream.render_duration_ms).round(3)
        )
      end

      def sum_render_duration(streams)
        streams.sum(&:render_duration_ms).round(3)
      end

      def shared_stream_name_for(planned_target, subscriber_ids:)
        return unless planned_target.sharing_signature
        return unless subscriber_ids.uniq.size > 1

        SharedStreams.stream_name(
          target: planned_target.shared_stream_target,
          identity_signature: planned_target.identity_signature,
          sharing_signature: planned_target.sharing_signature
        )
      end

      def target_selector_for(target)
        case target.kind
        when "page"
          %([data-upkeep-page-frame="#{css_escape(target.id)}"])
        when "fragment"
          %([data-upkeep-frame="#{css_escape(target.id)}"])
        when "render_site"
          %[upkeep-render-site[data-upkeep-render-site="#{css_escape(target.id)}"]]
        when "dom_id"
          %[##{css_escape(target.id)}]
        else
          raise "unknown delivery target kind: #{target.kind.inspect}"
        end
      end

      def css_escape(value)
        value.to_s.gsub("\\", "\\\\\\").gsub('"', '\"')
      end
    end
  end
end
