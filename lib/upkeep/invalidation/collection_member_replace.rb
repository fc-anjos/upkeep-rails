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
        replay = recipe.replay
        return unless replay.is_a?(Replay::Collection)
        return if replay.derived_partial?
        return unless update_change?

        collection = replay.collection
        return unless collection.is_a?(Replay::ActiveRecordRelationValue)
        return unless collection.primary_key
        return unless collection.member_ids.map(&:to_s).include?(change.fetch(:id).to_s)

        model = constantize(collection.model)
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
          replay: Replay::CollectionMember.new(
            controller_class: replay.controller_class,
            partial: replay.partial,
            record: Replay.active_record_value(record),
            options: replay.options
          )
        )
      end

      private

      attr_reader :recipe, :change

      def update_change?
        type = change.fetch(:type).to_s
        change[:id] && !type.include?("create") && !type.include?("destroy") && !type.include?("delete")
      end

      def relation_keeps_member_order?(model, collection)
        primary_key = collection.primary_key
        snapshot_ids = collection.member_ids.map(&:to_s)
        ordered_ids = model.find_by_sql(collection.sql).filter_map do |candidate|
          candidate_id = candidate.public_send(primary_key).to_s
          candidate_id if snapshot_ids.include?(candidate_id)
        end

        ordered_ids == snapshot_ids
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
