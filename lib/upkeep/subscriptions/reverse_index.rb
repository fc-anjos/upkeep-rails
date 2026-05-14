# frozen_string_literal: true

module Upkeep
  module Subscriptions
    class ReverseIndex
      Entry = Data.define(:subscription_id, :owner_id, :dependency_cache_key, :dependency)

      def initialize
        @entries_by_lookup_key = Hash.new { |hash, key| hash[key] = [] }
        @entry_keys_by_lookup_key = Hash.new { |hash, key| hash[key] = {} }
      end

      def index(subscription)
        index_entries(entries_for_subscription(subscription))
      end

      def index_entries(entries)
        entries.each do |entry|
          lookup_keys_for_dependency(entry.dependency).each do |lookup_key|
            entry_key = [entry.subscription_id, entry.owner_id, entry.dependency_cache_key]
            entry_keys = @entry_keys_by_lookup_key[lookup_key]
            next if entry_keys.key?(entry_key)

            @entries_by_lookup_key[lookup_key] << entry
            entry_keys[entry_key] = true
          end
        end
      end

      def entries_for(changes)
        changes
          .flat_map { |change| lookup_keys_for_change(change) }
          .flat_map { |lookup_key| @entries_by_lookup_key.fetch(lookup_key, []) }
          .uniq { |entry| [entry.subscription_id, entry.owner_id, entry.dependency_cache_key] }
      end

      def summary
        {
          lookup_keys: @entries_by_lookup_key.size,
          entries: @entries_by_lookup_key.values.sum(&:size)
        }
      end

      def entries_for_subscription(subscription)
        subscription.graph.dependency_nodes.flat_map do |node|
          subscription.graph.dependency_owner_ids(node.id).map do |owner_id|
            Entry.new(
              subscription.id,
              owner_id,
              node.payload.cache_key,
              node.payload
            )
          end
        end
      end

      def lookup_keys_for_dependency(dependency)
        case dependency.source
        when :active_record_attribute
          active_record_attribute_lookup_keys(dependency.key)
        when :active_record_collection
          active_record_collection_lookup_keys(dependency)
        else
          []
        end
      end

      def lookup_keys_for_change(change)
        table = change.fetch(:table)
        attributes = change.fetch(:changed_attributes, [])

        keys = attributes.map do |attribute|
          if change[:id]
            [:active_record_attribute, table, change.fetch(:id), attribute]
          else
            [:active_record_attribute_any_id, table, attribute]
          end
        end

        keys.concat(attributes.map { |attribute| [:active_record_collection_column, table, attribute] })
        keys.uniq
      end

      private

      def active_record_collection_lookup_keys(dependency)
        dependency.collection_lookup_columns.map { |table, column| [:active_record_collection_column, table, column] }
      end

      def active_record_attribute_lookup_keys(key)
        if key.fetch(:id)
          [[:active_record_attribute, key.fetch(:table), key.fetch(:id), key.fetch(:attribute)]]
        else
          [[:active_record_attribute_any_id, key.fetch(:table), key.fetch(:attribute)]]
        end
      end
    end
  end
end
