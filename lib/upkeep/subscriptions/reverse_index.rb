# frozen_string_literal: true

module Upkeep
  module Subscriptions
    class ReverseIndex
      COHORT_IDENTITY_SOURCES = %w[Current.user cookie current_attribute session warden_user].freeze

      Entry = Data.define(:subscription_id, :owner_id, :dependency_cache_key, :dependency, :subscriber_ids, :cohort_key) do
        def represented_subscriber_ids
          Array(subscriber_ids)
        end

        def cohort?
          !!cohort_key
        end
      end

      def initialize
        @entries_by_lookup_key = Hash.new { |hash, key| hash[key] = [] }
        @entry_keys_by_lookup_key = Hash.new { |hash, key| hash[key] = {} }
        @lookup_keys_by_subscription_id = Hash.new { |hash, key| hash[key] = {} }
        @cohort_entries_by_index_key = {}
        @cohort_members_by_index_key = Hash.new { |hash, key| hash[key] = {} }
        @cohort_index_keys_by_subscription_id = Hash.new { |hash, key| hash[key] = {} }
      end

      def index(subscription)
        index_entries(entries_for_subscription(subscription))
      end

      def index_entries(entries, subscription: nil)
        entries = entries_for_subscription_instance(entries, subscription) if subscription

        entries.each do |entry|
          lookup_keys_for_dependency(entry.dependency).each do |lookup_key|
            if entry.cohort?
              index_cohort_entry(lookup_key, entry)
            else
              index_direct_entry(lookup_key, entry)
            end
          end
        end
      end

      def delete_subscription(subscription_id)
        lookup_keys = @lookup_keys_by_subscription_id.delete(subscription_id)&.keys || []
        lookup_keys.each do |lookup_key|
          entries = @entries_by_lookup_key.fetch(lookup_key, nil)
          next unless entries

          entries.reject! { |entry| entry.subscription_id == subscription_id }
          @entry_keys_by_lookup_key[lookup_key].delete_if { |entry_key, _present| entry_key.fetch(0) == subscription_id }

          next unless entries.empty?

          @entries_by_lookup_key.delete(lookup_key)
          @entry_keys_by_lookup_key.delete(lookup_key)
        end

        cohort_index_keys = @cohort_index_keys_by_subscription_id.delete(subscription_id)&.keys || []
        cohort_index_keys.each { |index_key| delete_cohort_subscription(index_key, subscription_id) }
      end

      def entries_for(changes)
        raw_entries = changes
          .flat_map { |change| lookup_keys_for_change(change) }
          .flat_map { |lookup_key| @entries_by_lookup_key.fetch(lookup_key, []) }
          .uniq { |entry| [entry.subscription_id, entry.owner_id, entry.dependency_cache_key] }

        collapse_cohort_entries(raw_entries)
      end

      def summary
        {
          lookup_keys: @entries_by_lookup_key.size,
          entries: @entries_by_lookup_key.values.sum(&:size)
        }
      end

      def entries_for_subscription(subscription)
        subscription.recorder.flush_pending_dependencies if subscription.recorder.respond_to?(:flush_pending_dependencies)
        cohort_key = cohort_key_for(subscription)
        subscription.graph.dependency_nodes.flat_map do |node|
          subscription.graph.dependency_owner_ids(node.id).map do |owner_id|
            Entry.new(
              subscription.id,
              owner_id,
              node.payload.cache_key,
              node.payload,
              [subscription.subscriber_id],
              cohort_key
            )
          end
        end
      end

      def entries_for_subscription_instance(entries, subscription)
        entries.map { |entry| entry_for_subscription(entry, subscription) }
      end

      def lookup_keys_for_dependency(dependency)
        case dependency.source
        when :active_record_attribute
          active_record_attribute_lookup_keys(dependency.key)
        when :active_record_collection, :active_record_query
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

      def index_direct_entry(lookup_key, entry)
        entry_key = [entry.subscription_id, entry.owner_id, entry.dependency_cache_key]
        entry_keys = @entry_keys_by_lookup_key[lookup_key]
        return if entry_keys.key?(entry_key)

        @entries_by_lookup_key[lookup_key] << entry
        entry_keys[entry_key] = true
        @lookup_keys_by_subscription_id[entry.subscription_id][lookup_key] = true
      end

      def index_cohort_entry(lookup_key, entry)
        index_key = cohort_index_key(lookup_key, entry)
        members = @cohort_members_by_index_key[index_key]
        subscriber_ids = (members[entry.subscription_id] || []) | entry.represented_subscriber_ids
        return if members[entry.subscription_id] == subscriber_ids

        existing_entry = @cohort_entries_by_index_key[index_key]
        members[entry.subscription_id] = subscriber_ids
        replacement_entry = existing_entry ? append_cohort_members(existing_entry, subscriber_ids) : cohort_entry_from(entry, members)

        if existing_entry
          replace_entry(lookup_key, existing_entry, replacement_entry)
        else
          @entries_by_lookup_key[lookup_key] << replacement_entry
        end

        @cohort_entries_by_index_key[index_key] = replacement_entry
        @cohort_index_keys_by_subscription_id[entry.subscription_id][index_key] = true
      end

      def delete_cohort_subscription(index_key, subscription_id)
        lookup_key = index_key.fetch(0)
        members = @cohort_members_by_index_key.fetch(index_key, nil)
        return unless members&.key?(subscription_id)

        existing_entry = @cohort_entries_by_index_key.fetch(index_key)
        members.delete(subscription_id)

        if members.empty?
          remove_entry(lookup_key, existing_entry)
          @cohort_members_by_index_key.delete(index_key)
          @cohort_entries_by_index_key.delete(index_key)
        else
          replacement_entry = cohort_entry_from(existing_entry, members)
          replace_entry(lookup_key, existing_entry, replacement_entry)
          @cohort_entries_by_index_key[index_key] = replacement_entry
        end
      end

      def cohort_index_key(lookup_key, entry)
        [lookup_key, entry.cohort_key, entry.owner_id, entry.dependency_cache_key]
      end

      def cohort_entry_from(entry, members)
        Entry.new(
          members.keys.sort_by(&:to_s).first,
          entry.owner_id,
          entry.dependency_cache_key,
          entry.dependency,
          members.values.flatten.uniq.sort_by(&:to_s),
          entry.cohort_key
        )
      end

      def append_cohort_members(entry, subscriber_ids)
        Entry.new(
          entry.subscription_id,
          entry.owner_id,
          entry.dependency_cache_key,
          entry.dependency,
          entry.represented_subscriber_ids | subscriber_ids,
          entry.cohort_key
        )
      end

      def replace_entry(lookup_key, existing_entry, replacement_entry)
        entries = @entries_by_lookup_key.fetch(lookup_key)
        index = entries.index(existing_entry)
        entries[index] = replacement_entry if index
      end

      def remove_entry(lookup_key, entry)
        entries = @entries_by_lookup_key.fetch(lookup_key, nil)
        return unless entries

        entries.delete(entry)

        return unless entries.empty?

        @entries_by_lookup_key.delete(lookup_key)
        @entry_keys_by_lookup_key.delete(lookup_key)
      end

      def entry_for_subscription(entry, subscription)
        Entry.new(
          entry.subscription_id || subscription.id,
          entry.owner_id,
          entry.dependency_cache_key,
          entry.dependency,
          entry.subscriber_ids || [subscription.subscriber_id],
          entry.cohort_key || cohort_key_for(subscription)
        )
      end

      def collapse_cohort_entries(entries)
        direct_entries = []
        cohort_entries = Hash.new { |hash, key| hash[key] = [] }

        entries.each do |entry|
          if entry.cohort?
            cohort_entries[[entry.cohort_key, entry.owner_id, entry.dependency_cache_key]] << entry
          else
            direct_entries << entry
          end
        end

        direct_entries + cohort_entries.values.map { |group| collapse_cohort_entry_group(group) }
      end

      def collapse_cohort_entry_group(entries)
        representative = entries.first
        Entry.new(
          representative.subscription_id,
          representative.owner_id,
          representative.dependency_cache_key,
          representative.dependency,
          entries.flat_map(&:represented_subscriber_ids).uniq.sort_by(&:to_s),
          representative.cohort_key
        )
      end

      def cohort_key_for(subscription)
        return unless identity_free_subscription?(subscription)

        metadata_value(subscription, :subscription_shape_key)
      end

      def identity_free_subscription?(subscription)
        return false if subscription.graph.dependency_nodes.any? { |node| cohort_identity_dependency?(node.payload) }

        true
      end

      def metadata_value(subscription, key)
        subscription.metadata[key] || subscription.metadata[key.to_s]
      end

      def cohort_identity_dependency?(dependency)
        Dependencies.partitioning_identity?(dependency) && COHORT_IDENTITY_SOURCES.include?(dependency.source.to_s)
      end

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
