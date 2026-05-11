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
        replay = symbolize_keys(recipe.replay)
        return unless replay[:type] == "collection"
        return if replay[:partial] == "derived"
        return unless create_change?

        collection = symbolize_keys(replay.fetch(:collection))
        return unless collection[:type] == "active_record_relation"
        return unless appendable_sql?(collection.fetch(:sql))

        model = constantize(collection.fetch(:model))
        record = model.find_by(id: change.fetch(:id))
        return unless record && relation_appends_record?(model, collection.fetch(:sql), record)

        Replay::Recipe.new(
          kind: :render_site_append,
          frame_id: recipe.frame_id,
          target_kind: recipe.target_kind,
          target_id: recipe.target_id,
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

      def create_change?
        change[:id] && change.fetch(:type).to_s.include?("create")
      end

      def relation_appends_record?(model, sql, record)
        last_record = model.find_by_sql(sql).last
        last_record && last_record.id.to_s == record.id.to_s
      end

      def appendable_sql?(sql)
        normalized = sql.to_s.upcase
        !normalized.match?(/\b(LIMIT|OFFSET|GROUP BY|HAVING|DISTINCT)\b/)
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
