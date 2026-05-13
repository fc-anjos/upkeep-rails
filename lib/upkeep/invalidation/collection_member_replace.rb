# frozen_string_literal: true

module Upkeep
  module Invalidation
    class CollectionMemberReplace
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
        return if replay[:partial] == "derived"
        return unless update_change?

        collection = symbolize_keys(replay.fetch(:collection))
        return unless collection[:type] == "active_record_relation"
        return unless collection[:primary_key]
        return unless collection.fetch(:member_ids, []).map(&:to_s).include?(change.fetch(:id).to_s)

        model = constantize(collection.fetch(:model))
        return unless change.fetch(:table) == model.table_name

        record = model.find_by(id: change.fetch(:id))
        return unless record && relation_keeps_member_order?(model, collection)

        Replay::Recipe.new(
          kind: :render_site_member_replace,
          frame_id: recipe.frame_id,
          target_kind: "dom_id",
          target_id: dom_id(model, change.fetch(:id)),
          template: recipe.template,
          metadata: recipe.metadata,
          runtime: "rails",
          replay: {
            type: "collection_member",
            controller_class: replay[:controller_class],
            partial: replay.fetch(:partial),
            record: snapshot_record(record),
            options: replay.fetch(:options, {})
          }.compact
        )
      end

      private

      attr_reader :recipe, :change

      def update_change?
        type = change.fetch(:type).to_s
        change[:id] && !type.include?("create") && !type.include?("destroy") && !type.include?("delete")
      end

      def relation_keeps_member_order?(model, collection)
        primary_key = collection.fetch(:primary_key)
        snapshot_ids = collection.fetch(:member_ids, []).map(&:to_s)
        ordered_ids = model.find_by_sql(collection.fetch(:sql)).filter_map do |candidate|
          candidate_id = candidate.public_send(primary_key).to_s
          candidate_id if snapshot_ids.include?(candidate_id)
        end

        ordered_ids == snapshot_ids
      end

      def dom_id(model, id)
        "#{model.model_name.param_key}_#{id}"
      end

      def snapshot_record(record)
        { type: "active_record", model: record.class.name, id: record.id }
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
