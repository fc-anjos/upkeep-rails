# frozen_string_literal: true

module Upkeep
  module Replay
    class Recipe
      attr_reader :kind, :frame_id, :target_kind, :target_id, :template, :metadata

      def initialize(kind:, frame_id:, target_kind:, target_id:, template: nil, metadata: {}, &renderer)
        @kind = kind
        @frame_id = frame_id
        @target_kind = target_kind
        @target_id = target_id
        @template = template
        @metadata = metadata
        @renderer = renderer
      end

      def render
        raise "replay recipe has no renderer" unless @renderer

        @renderer.call
      end

      def to_h
        {
          kind: kind,
          frame_id: frame_id,
          target_kind: target_kind,
          target_id: target_id,
          template: template,
          metadata: metadata
        }.compact
      end
    end
  end
end
