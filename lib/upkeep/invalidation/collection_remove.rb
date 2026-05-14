# frozen_string_literal: true

module Upkeep
  module Invalidation
    class CollectionRemove
      def self.build(recipe:, change:)
        new(recipe, change).build
      end

      def initialize(recipe, change)
        @recipe = recipe
        @change = change
      end

      def build
        replay = recipe.replay
        return unless replay.is_a?(Replay::Collection)
        return unless destroy_change?

        collection = replay.collection
        return unless collection.is_a?(Replay::ActiveRecordRelationValue)
        return unless collection.member_ids.map(&:to_s).include?(change.fetch(:id).to_s)

        model = constantize(collection.model)
        return unless change.fetch(:table) == model.table_name

        Replay::Recipe.new(
          kind: :render_site_remove,
          frame_id: recipe.frame_id,
          target_kind: "dom_id",
          target_id: dom_id(model, change.fetch(:id)),
          template: recipe.template,
          metadata: recipe.metadata,
          runtime: "rails",
          replay: Replay::Empty.new
        )
      end

      private

      attr_reader :recipe, :change

      def destroy_change?
        type = change.fetch(:type).to_s
        change[:id] && (type.include?("destroy") || type.include?("delete"))
      end

      def dom_id(model, id)
        "#{model.model_name.param_key}_#{id}"
      end

      def constantize(name)
        name.to_s.split("::").reduce(Object) { |namespace, constant_name| namespace.const_get(constant_name) }
      end
    end
  end
end
