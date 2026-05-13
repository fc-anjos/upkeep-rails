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
        replay = symbolize_keys(recipe.replay)
        return unless replay[:type] == "collection"
        return unless destroy_change?

        collection = symbolize_keys(replay.fetch(:collection))
        return unless collection[:type] == "active_record_relation"
        return unless collection.fetch(:member_ids, []).map(&:to_s).include?(change.fetch(:id).to_s)

        model = constantize(collection.fetch(:model))
        return unless change.fetch(:table) == model.table_name

        Replay::Recipe.new(
          kind: :render_site_remove,
          frame_id: recipe.frame_id,
          target_kind: "dom_id",
          target_id: dom_id(model, change.fetch(:id)),
          template: recipe.template,
          metadata: recipe.metadata,
          runtime: "rails",
          replay: {}
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

      def symbolize_keys(value)
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
    end
  end
end
