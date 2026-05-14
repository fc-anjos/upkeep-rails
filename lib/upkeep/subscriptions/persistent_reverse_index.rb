# frozen_string_literal: true

require "digest"
require "json"
require_relative "../dependencies"
require_relative "json_snapshot"
require_relative "reverse_index"

module Upkeep
  module Subscriptions
    class PersistentReverseIndex
      def initialize(reverse_index:, index_record:)
        @reverse_index = reverse_index
        @index_record = index_record
      end

      def entries_for(changes)
        persistent_entries_for(changes)
      end

      def summary
        {
          lookup_keys: index_record.distinct.count(:lookup_key_digest),
          entries: index_record.count
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

      attr_reader :reverse_index, :index_record

      def persistent_entries_for(changes)
        lookup_keys = Array(changes).flat_map { |change| reverse_index.lookup_keys_for_change(change) }.uniq
        lookup_keys_by_digest = Hash.new { |hash, digest| hash[digest] = [] }
        lookup_keys.each do |lookup_key|
          lookup_keys_by_digest[self.class.digest(lookup_key)] << lookup_key
        end
        lookup_key_digests = lookup_keys_by_digest.keys

        index_record
          .where(lookup_key_digest: lookup_key_digests)
            .pluck(
              :subscription_id,
              :lookup_key_digest,
              :owner_ids_snapshot,
              :dependency_cache_key_snapshot,
              :dependency_snapshot
            )
            .flat_map { |row| entries_for_row(row, lookup_keys_by_digest) }
            .uniq { |entry| [entry.subscription_id, entry.owner_id, entry.dependency_cache_key] }
      end

      def entries_for_row(row, lookup_keys_by_digest)
        subscription_id, lookup_key_digest, owner_ids_snapshot, dependency_cache_key_snapshot, dependency_snapshot = row
        return [] unless lookup_keys_by_digest.key?(lookup_key_digest)

        dependency_cache_key = JsonSnapshot.load(dependency_cache_key_snapshot)
        dependency = Dependencies.from_h(JsonSnapshot.load(dependency_snapshot))
        JsonSnapshot.load(owner_ids_snapshot).map do |owner_id|
          ReverseIndex::Entry.new(
            subscription_id,
            owner_id,
            dependency_cache_key,
            dependency
          )
        end
      end
    end
  end
end
