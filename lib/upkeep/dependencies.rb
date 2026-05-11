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

    class WardenUser < Identity
      def initialize(scope:, user:)
        super(
          source: :warden_user,
          key: scope.to_s,
          value: Dependencies.model_identity(user),
          metadata: Dependencies.model_metadata(user).merge(scope: scope.to_s)
        )
      end
    end

    class CurrentAttribute < Identity
      def initialize(owner:, name:, value:)
        super(
          source: :current_attribute,
          key: "#{owner}.#{name}",
          value: Dependencies.canonical_identity(value),
          metadata: { owner: owner.to_s, name: name.to_s }
        )
      end
    end

    class SessionValue < Identity
      def initialize(key:, value:)
        super(
          source: :session,
          key: key.to_s,
          value: Dependencies.private_fingerprint(value),
          metadata: { key: key.to_s, value_class: value.class.name }
        )
      end
    end

    class CookieValue < Identity
      def initialize(key:, value:)
        super(
          source: :cookie,
          key: key.to_s,
          value: Dependencies.private_fingerprint(value),
          metadata: { key: key.to_s, value_class: value.class.name }
        )
      end
    end

    class RequestValue < Identity
      def initialize(key:, value:)
        super(
          source: :request,
          key: key.to_s,
          value: Dependencies.private_fingerprint(value),
          metadata: { key: key.to_s, value_class: value.class.name }
        )
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

    class Restored < Base
      def initialize(source:, key:, metadata:, visibility:, precision:)
        super(source: source, key: key, metadata: metadata)
        @visibility = visibility.to_sym
        @precision = precision.to_sym
      end

      def identity?
        visibility == :identity_bound
      end

      def identity_key
        return unless identity?

        { source: source, key: key.fetch(:key), value: key.fetch(:value) }
      end

      attr_reader :visibility, :precision
    end

    module_function

    def from_h(snapshot)
      snapshot = symbolize_keys(snapshot)
      source = snapshot.fetch(:source)
      key = symbolize_keys(snapshot.fetch(:key))
      metadata = symbolize_keys(snapshot.fetch(:metadata, {}))

      case source.to_sym
      when :active_record_attribute
        ActiveRecordAttribute.new(
          table: key.fetch(:table),
          id: key.fetch(:id),
          attribute: key.fetch(:attribute),
          model: metadata[:model]
        )
      when :active_record_collection
        ActiveRecordCollection.new(
          table: key.fetch(:table),
          columns: metadata.fetch(:columns),
          sql: metadata.fetch(:sql)
        )
      else
        if snapshot.fetch(:visibility).to_sym == :identity_bound
          Identity.new(
            source: source,
            key: key.fetch(:key),
            value: key.fetch(:value),
            metadata: metadata
          )
        else
          Restored.new(
            source: source,
            key: key,
            metadata: metadata,
            visibility: snapshot.fetch(:visibility),
            precision: snapshot.fetch(:precision)
          )
        end
      end
    end

    def model_identity(value)
      return nil unless value

      if value.respond_to?(:id) && value.class.respond_to?(:name)
        { model: value.class.name, id: value.id }
      end
    end

    def model_metadata(value)
      return {} unless value

      {
        model: value.class.name,
        table: value.class.respond_to?(:table_name) ? value.class.table_name : nil,
        id: value.respond_to?(:id) ? value.id : nil
      }.compact
    end

    def canonical_identity(value)
      case value
      when nil, true, false, Numeric, String, Symbol
        value
      else
        model_identity(value) || private_fingerprint(value)
      end
    end

    def private_fingerprint(value)
      Digest::SHA256.hexdigest(Marshal.dump(value))[0, 16]
    rescue TypeError
      Digest::SHA256.hexdigest(value.inspect)[0, 16]
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
