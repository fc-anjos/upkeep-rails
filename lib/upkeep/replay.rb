# frozen_string_literal: true

module Upkeep
  module Replay
    class Recipe
      attr_reader :kind, :frame_id, :target_kind, :target_id, :template, :metadata, :runtime, :replay

      def initialize(kind:, frame_id:, target_kind:, target_id:, template: nil, metadata: {}, runtime: nil, replay: {}, &renderer)
        @kind = kind
        @frame_id = frame_id
        @target_kind = target_kind
        @target_id = target_id
        @template = template
        @metadata = metadata
        @runtime = runtime
        @replay = replay
        @renderer = renderer
      end

      def render
        return @renderer.call if @renderer

        runtime_renderer.render(self)
      end

      def render_target(target)
        html = render
        return html if target_match?(target)

        require_relative "targeting"
        Targeting::Extraction.extract_target_html(html, target)
      end

      def target_match?(target)
        target && target.kind != "page" && target.kind == target_kind && target.id == target_id
      end

      def manifest_target_render?(target)
        !!manifest_reference && target_match?(target)
      end

      def manifest_reference
        metadata[:manifest] || metadata["manifest"]
      end

      def to_h
        snapshot = {
          kind: kind,
          frame_id: frame_id,
          target_kind: target_kind,
          target_id: target_id,
          template: template,
          metadata: metadata
        }.compact

        snapshot[:runtime] = runtime if runtime
        snapshot[:replay] = replay if replay && !replay.empty?
        snapshot
      end

      def self.from_h(snapshot)
        snapshot = symbolize_keys(snapshot)

        new(
          kind: snapshot.fetch(:kind),
          frame_id: snapshot.fetch(:frame_id),
          target_kind: snapshot.fetch(:target_kind),
          target_id: snapshot.fetch(:target_id),
          template: snapshot[:template],
          metadata: snapshot.fetch(:metadata, {}),
          runtime: snapshot[:runtime],
          replay: snapshot.fetch(:replay, {})
        )
      end

      def self.symbolize_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), result|
            normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
            result[normalized_key] = symbolize_keys(nested_value)
          end
        when Array
          value.map { |nested_value| symbolize_keys(nested_value) }
        else
          value
        end
      end

      private

      def runtime_renderer
        case runtime
        when "rails"
          require_relative "rails/replay"
          Upkeep::Rails::Replay
        else
          raise "replay recipe has no renderer"
        end
      end
    end
  end
end
