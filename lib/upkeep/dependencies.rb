# frozen_string_literal: true

require "digest"

module Upkeep
  module Dependencies
    class Base
      attr_reader :source, :key, :metadata

      def initialize(source:, key:, metadata: {})
        @source = source
        @key = key
        @metadata = metadata
      end

      def cache_key
        [source, key]
      end

      def matches_change?(_change)
        false
      end

      def identity?
        false
      end

      def identity_key
        nil
      end

      def visibility
        :public
      end

      def precision
        :unknown
      end

      def narrow_frame_safe?
        false
      end

      def to_h
        {
          source: source,
          key: key,
          visibility: visibility,
          precision: precision,
          metadata: metadata
        }
      end
    end

    class ActiveRecordAttribute < Base
      def initialize(table:, id:, attribute:, model: nil)
        super(
          source: :active_record_attribute,
          key: { table: table, id: id, attribute: attribute },
          metadata: { model: model }.compact
        )
      end

      def matches_change?(change)
        key.fetch(:table) == change.fetch(:table) &&
          (!change[:id] || key.fetch(:id) == change[:id]) &&
          change.fetch(:changed_attributes, []).include?(key.fetch(:attribute))
      end

      def precision
        :record_attribute
      end

      def narrow_frame_safe?
        true
      end
    end

    class ActiveRecordCollection < Base
      def initialize(table:, columns:, sql:)
        super(
          source: :active_record_collection,
          key: {
            table: table,
            predicate_digest: Digest::SHA256.hexdigest(sql)[0, 16]
          },
          metadata: {
            columns: columns.sort,
            sql: sql
          }
        )
      end

      def matches_change?(change)
        return false unless key.fetch(:table) == change.fetch(:table)

        metadata.fetch(:columns).intersect?(change.fetch(:changed_attributes, [])) ||
          change.fetch(:type).to_s.include?("create") ||
          change.fetch(:type).to_s.include?("delete")
      end

      def precision
        :collection_predicate
      end
    end

    class Identity < Base
      def initialize(source:, key:, value:, metadata: {})
        super(
          source: source,
          key: { key: key, value: value },
          metadata: metadata
        )
      end

      def identity?
        true
      end

      def identity_key
        { source: source, key: key.fetch(:key), value: key.fetch(:value) }
      end

      def visibility
        :identity_bound
      end

      def precision
        :identity
      end
    end

    class Unknown < Base
      def initialize(source:, metadata: {})
        super(
          source: source,
          key: Digest::SHA256.hexdigest(metadata.inspect)[0, 16],
          metadata: metadata
        )
      end

      def visibility
        :private
      end
    end
  end
end
