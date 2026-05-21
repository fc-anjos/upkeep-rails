# frozen_string_literal: true

require "digest"
require "json"
require_relative "../dependencies"
require_relative "json_snapshot"
require_relative "reverse_index"

module Upkeep
  module Subscriptions
    class PersistentReverseIndex
      LOOKUP_COLUMNS = [
        :subscription_id,
        :lookup_key_digest,
        :dependency_source,
        :lookup_table,
        :lookup_record_id_snapshot,
        :lookup_attribute,
        :dependency_table,
        :dependency_predicate_digest,
        :dependency_metadata_snapshot,
        :owner_ids_snapshot
      ].freeze

      SHAPE_LOOKUP_COLUMNS = [
        :subscription_shape_key,
        :lookup_key_digest,
        :dependency_source,
        :lookup_table,
        :lookup_record_id_snapshot,
        :lookup_attribute,
        :dependency_table,
        :dependency_predicate_digest,
        :dependency_metadata_snapshot,
        :owner_ids_snapshot
      ].freeze

      def initialize(reverse_index:, index_record:, shape_index_record:, subscription_record:)
        @reverse_index = reverse_index
        @index_record = index_record
        @shape_index_record = shape_index_record
        @subscription_record = subscription_record
      end

      def entries_for(changes)
        persistent_entries_for(changes)
      end

      def summary
        lookup_key_digests = index_record.distinct.pluck(:lookup_key_digest) +
          shape_index_record.distinct.pluck(:lookup_key_digest)
        {
          lookup_keys: lookup_key_digests.uniq.size,
          entries: index_record.count + shape_index_record.count
        }
      end

      def self.digest(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical_lookup_value(value)))
      end

      def self.canonical_lookup_value(value)
        case value
        when Array
          value.map { |item| canonical_lookup_value(item) }
        when Hash
          value.keys.sort_by(&:to_s).map do |key|
            [canonical_lookup_value(key), canonical_lookup_value(value.fetch(key))]
          end
        when Symbol
          ["symbol", value.to_s]
        when String
          ["string", value.encode(Encoding::UTF_8)]
        else
          value
        end
      end

      private

      attr_reader :reverse_index, :index_record, :shape_index_record, :subscription_record

      def persistent_entries_for(changes)
        lookup_keys = Array(changes).flat_map { |change| reverse_index.lookup_keys_for_change(change) }.uniq
        lookup_keys_by_digest = Hash.new { |hash, digest| hash[digest] = [] }
        lookup_keys.each do |lookup_key|
          lookup_keys_by_digest[self.class.digest(lookup_key)] << lookup_key
        end
        lookup_key_digests = lookup_keys_by_digest.keys

        direct_entries = index_record
          .where(lookup_key_digest: lookup_key_digests)
          .pluck(*LOOKUP_COLUMNS)
          .flat_map { |row| entries_for_row(row, lookup_keys_by_digest) }

        shape_entries = shape_entries_for(lookup_key_digests, lookup_keys_by_digest)

        (direct_entries + shape_entries).uniq { |entry| [entry.subscription_id, entry.owner_id, entry.dependency_cache_key] }
      end

      def shape_entries_for(lookup_key_digests, lookup_keys_by_digest)
        shape_rows = shape_index_record
          .where(lookup_key_digest: lookup_key_digests)
          .pluck(*SHAPE_LOOKUP_COLUMNS)
        return [] if shape_rows.empty?

        subscription_ids_by_shape_key = subscription_ids_by_shape_key(
          shape_rows.map { |row| row.fetch(0) }.uniq
        )
        shape_rows.flat_map do |row|
          entries_for_shape_row(row, lookup_keys_by_digest, subscription_ids_by_shape_key)
        end
      end

      def entries_for_row(row, lookup_keys_by_digest)
        attributes = LOOKUP_COLUMNS.zip(row).to_h
        lookup_keys = lookup_keys_by_digest.fetch(attributes.fetch(:lookup_key_digest)) { return [] }
        return [] unless lookup_keys.any? { |lookup_key| lookup_key_matches_row?(lookup_key, attributes) }

        dependency = dependency_for_row(attributes)
        dependency_cache_key = dependency.cache_key
        JsonSnapshot.load(attributes.fetch(:owner_ids_snapshot)).map do |owner_id|
          ReverseIndex::Entry.new(
            attributes.fetch(:subscription_id),
            owner_id,
            dependency_cache_key,
            dependency,
            nil,
            nil
          )
        end
      end

      def entries_for_shape_row(row, lookup_keys_by_digest, subscription_ids_by_shape_key)
        attributes = SHAPE_LOOKUP_COLUMNS.zip(row).to_h
        lookup_keys = lookup_keys_by_digest.fetch(attributes.fetch(:lookup_key_digest)) { return [] }
        return [] unless lookup_keys.any? { |lookup_key| lookup_key_matches_row?(lookup_key, attributes) }

        dependency = dependency_for_row(attributes)
        dependency_cache_key = dependency.cache_key
        subscription_ids = subscription_ids_by_shape_key.fetch(attributes.fetch(:subscription_shape_key), [])
        subscription_ids.flat_map do |subscription_id|
          JsonSnapshot.load(attributes.fetch(:owner_ids_snapshot)).map do |owner_id|
            ReverseIndex::Entry.new(
              subscription_id,
              owner_id,
              dependency_cache_key,
              dependency,
              nil,
              nil
            )
          end
        end
      end

      def lookup_key_matches_row?(lookup_key, attributes)
        case lookup_key.fetch(0)
        when :active_record_attribute
          lookup_key.fetch(1).to_s == attributes.fetch(:lookup_table).to_s &&
            lookup_key.fetch(2) == JsonSnapshot.load(attributes.fetch(:lookup_record_id_snapshot)) &&
            lookup_key.fetch(3).to_s == attributes.fetch(:lookup_attribute).to_s
        when :active_record_attribute_any_id
          lookup_key.fetch(1).to_s == attributes.fetch(:lookup_table).to_s &&
            attributes.fetch(:lookup_record_id_snapshot).nil? &&
            lookup_key.fetch(2).to_s == attributes.fetch(:lookup_attribute).to_s
        when :active_record_collection_column
          lookup_key.fetch(1).to_s == attributes.fetch(:lookup_table).to_s &&
            attributes.fetch(:lookup_record_id_snapshot).nil? &&
            lookup_key.fetch(2).to_s == attributes.fetch(:lookup_attribute).to_s
        else
          false
        end
      end

      def dependency_for_row(attributes)
        source = attributes.fetch(:dependency_source).to_sym
        case source
        when :active_record_attribute
          Dependencies::ActiveRecordAttribute.new(
            table: attributes.fetch(:dependency_table),
            id: attributes[:lookup_record_id_snapshot] && JsonSnapshot.load(attributes.fetch(:lookup_record_id_snapshot)),
            attribute: attributes.fetch(:lookup_attribute)
          )
        when :active_record_collection, :active_record_query
          metadata = JsonSnapshot.load(attributes.fetch(:dependency_metadata_snapshot))
          dependency_class = source == :active_record_query ? Dependencies::ActiveRecordQuery : Dependencies::ActiveRecordCollection
          dependency_class.new(
            primary_table: attributes.fetch(:dependency_table),
            table_columns: metadata.fetch(:table_columns),
            coverage: metadata.fetch(:coverage),
            sql: metadata.fetch(:sql),
            predicates: metadata.fetch(:predicates)
          )
        else
          raise ArgumentError, "unsupported persistent dependency source: #{source.inspect}"
        end
      end

      def subscription_ids_by_shape_key(shape_keys)
        shape_key_lookup = shape_keys.to_h { |shape_key| [shape_key, []] }
        subscription_record
          .where(subscription_shape_key: shape_keys)
          .pluck(:subscription_shape_key, :id)
          .each do |shape_key, id|
            shape_key_lookup[shape_key] << id if shape_key_lookup.key?(shape_key)
          end
        shape_key_lookup.transform_values { |ids| ids.sort_by(&:to_s) }
      end
    end
  end
end
