# frozen_string_literal: true

module Upkeep
  module Invalidation
    class CollectionAppend
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
        return unless create_change?

        collection = replay.collection
        return unless collection.is_a?(Replay::ActiveRecordRelationValue)
        return unless collection.primary_key
        return unless collection.appendable?

        model = constantize(collection.model)
        return unless change.fetch(:table) == model.table_name

        record = model.find_by(id: change.fetch(:id))
        return unless record && relation_appends_record?(model, collection, record)

        Replay::Recipe.new(
          kind: :render_site_append,
          frame_id: recipe.frame_id,
          target_kind: recipe.target_kind,
          target_id: recipe.target_id,
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

      def create_change?
        change[:id] && change.fetch(:type).to_s.include?("create")
      end

      def relation_appends_record?(model, collection, record)
        primary_key = collection.primary_key
        snapshot_ids = collection.member_ids.map(&:to_s)
        candidate_ids = (snapshot_ids + [record.public_send(primary_key).to_s]).uniq
        ordered_ids = model.find_by_sql(collection.sql).filter_map do |candidate|
          candidate_id = candidate.public_send(primary_key).to_s
          candidate_id if candidate_ids.include?(candidate_id)
        end

        ordered_ids.last == record.public_send(primary_key).to_s &&
          (snapshot_ids - ordered_ids).empty?
      end

      def constantize(name)
        name.to_s.split("::").reduce(Object) { |namespace, constant_name| namespace.const_get(constant_name) }
      end
    end
  end
end
