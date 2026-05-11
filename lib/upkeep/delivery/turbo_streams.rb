# frozen_string_literal: true

require "cgi"

module Upkeep
  module Delivery
    class TurboStreams
      Stream = Data.define(
        :action,
        :target,
        :target_selector,
        :html,
        :html_digest,
        :identity_signature,
        :subscriber_ids,
        :matched_dependency_keys
      ) do
        def to_html
          attributes = %(action="#{CGI.escapeHTML(action)}" targets="#{CGI.escapeHTML(target_selector)}")

          %(<turbo-stream #{attributes}><template>#{html}</template></turbo-stream>)
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
            html_digest: html_digest,
            subscriber_ids: subscriber_ids,
            matched_dependency_keys: matched_dependency_keys
          }
        end
      end

      Envelope = Data.define(:subscriber_id, :streams) do
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
          streams
            .flat_map(&:subscriber_ids)
            .uniq
            .sort_by(&:to_s)
            .map { |subscriber_id| envelope_for(subscriber_id) }
        end

        def envelope_for(subscriber_id)
          Envelope.new(subscriber_id, streams.select { |stream| stream.for_subscriber?(subscriber_id) })
        end

        def report
          {
            streams: streams.map(&:report),
            envelopes: envelopes.map(&:report)
          }
        end
      end

      def build(plan)
        streams = plan.targets.map { |planned_target| stream_for(planned_target) }
        Batch.new(merge_streams(streams))
      end

      private

      def stream_for(planned_target)
        html = planned_target.render

        Stream.new(
          "replace",
          planned_target.target,
          target_selector_for(planned_target.target),
          html,
          Targeting::Extraction.digest_html(html),
          planned_target.identity_signature,
          [planned_target.subscriber_id],
          planned_target.matched_dependency_keys
        )
      end

      def merge_streams(streams)
        streams.each_with_object({}) do |stream, indexed_streams|
          key = [stream.target.kind, stream.target.id, stream.identity_signature, stream.html_digest]
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
          (existing.subscriber_ids + stream.subscriber_ids).uniq.sort_by(&:to_s),
          (existing.matched_dependency_keys + stream.matched_dependency_keys).uniq
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
