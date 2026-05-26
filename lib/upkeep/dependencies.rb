# frozen_string_literal: true

require "digest"
require "json"

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
          (key.fetch(:id).nil? || !change[:id] || key.fetch(:id) == change[:id]) &&
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
      UNKNOWN = Object.new

      def initialize(
        primary_table:,
        table_columns:,
        coverage:,
        sql:,
        predicates: [],
        source: :active_record_collection,
        precision: :collection_predicate
      )
        table_columns = normalize_table_columns(table_columns)
        coverage = coverage.to_sym
        unless coverage == :columns
          raise ArgumentError,
            "unsupported Active Record predicate coverage: #{coverage}; collection dependencies require proven column coverage"
        end

        @precision = precision.to_sym
        super(
          source: source.to_sym,
          key: {
            table: primary_table,
            predicate_digest: Digest::SHA256.hexdigest(sql)[0, 16]
          },
          metadata: {
            primary_table: primary_table,
            table_columns: table_columns,
            coverage: coverage.to_s,
            sql: sql,
            predicates: normalize_predicates(predicates)
          }
        )
      end

      def matches_change?(change)
        return false unless table_columns.key?(change.fetch(:table))

        predicate_match = predicate_match(change)
        return predicate_match unless predicate_match == UNKNOWN

        return true if create_change?(change)
        return true if delete_change?(change)

        table_columns.fetch(change.fetch(:table)).intersect?(change.fetch(:changed_attributes, []))
      end

      def precision
        @precision
      end

      def collection_lookup_tables
        table_columns.keys.sort
      end

      def collection_lookup_columns
        table_columns.flat_map do |table, columns|
          columns.map { |column| [table, column] }
        end.sort
      end

      private

      def predicate_match(change)
        predicates = predicates_for_table(change.fetch(:table))
        return UNKNOWN if predicates.empty?

        old_match = values_match_predicates(change.fetch(:old_values, {}), predicates)
        new_match = values_match_predicates(change.fetch(:new_values, {}), predicates)
        return true if old_match == true || new_match == true

        if old_match == false || new_match == false
          return false if predicate_columns(predicates).intersect?(change.fetch(:changed_attributes, [])) ||
            create_change?(change) ||
            delete_change?(change)
        end

        UNKNOWN
      end

      def create_change?(change)
        change.fetch(:type).to_s.include?("create")
      end

      def delete_change?(change)
        type = change.fetch(:type).to_s
        type.include?("delete") || type.include?("destroy")
      end

      def values_match_predicates(values, predicates)
        values = stringify_keys(values)
        return UNKNOWN unless predicates.all? { |predicate| values.key?(predicate.fetch(:column)) }

        predicates.all? do |predicate|
          value = values.fetch(predicate.fetch(:column))
          predicate.fetch(:values).include?(value)
        end
      end

      def predicates_for_table(table)
        predicates.select { |predicate| predicate.fetch(:table) == table.to_s }
      end

      def predicate_columns(predicates)
        predicates.map { |predicate| predicate.fetch(:column) }.uniq
      end

      def coverage
        metadata.fetch(:coverage).to_sym.tap do |value|
          raise ArgumentError, "unsupported Active Record collection coverage: #{value}" unless value == :columns
        end
      end

      def table_columns
        metadata.fetch(:table_columns)
      end

      def predicates
        metadata.fetch(:predicates)
      end

      def normalize_table_columns(value)
        Dependencies.symbolize_keys(value).to_h do |table, columns|
          [table.to_s, Array(columns).map(&:to_s).uniq.sort]
        end
      end

      def normalize_predicates(value)
        Array(value).filter_map do |predicate|
          predicate = Dependencies.symbolize_keys(predicate)
          values = Array(predicate[:values]).compact
          next if predicate[:table].nil? || predicate[:column].nil? || values.empty?

          {
            table: predicate.fetch(:table).to_s,
            column: predicate.fetch(:column).to_s,
            operator: predicate.fetch(:operator, "eq").to_s,
            values: values.uniq
          }
        end
      end

      def stringify_keys(values)
        values.to_h.transform_keys(&:to_s)
      end
    end

    class ActiveRecordQuery < ActiveRecordCollection
      def initialize(primary_table:, table_columns:, coverage:, sql:, predicates: [])
        super(
          primary_table: primary_table,
          table_columns: table_columns,
          coverage: coverage,
          sql: sql,
          predicates: predicates,
          source: :active_record_query,
          precision: :query_predicate
        )
      end
    end

    class Identity < Base
      def initialize(source:, key:, value:, metadata: {}, partitioning: nil, absent_by_name: nil)
        metadata = metadata.dup
        metadata[:partitioning_identity] = partitioning unless partitioning.nil?
        if absent_by_name&.any?
          metadata[:identity_absent_by_name] = absent_by_name.to_h.transform_keys(&:to_s)
        end

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

      def nil_identity?
        return true if key.fetch(:value).nil?

        value_class = metadata[:value_class] || metadata["value_class"]
        value_class.to_s == "NilClass"
      end

      def visibility
        :identity_bound
      end

      def precision
        :identity
      end
    end

    class WardenUser < Identity
      def initialize(scope:, user:, partitioning: nil, absent_by_name: nil)
        super(
          source: :warden_user,
          key: scope.to_s,
          value: Dependencies.model_identity(user),
          metadata: Dependencies.model_metadata(user).merge(scope: scope.to_s),
          partitioning: partitioning,
          absent_by_name: absent_by_name
        )
      end
    end

    class CurrentAttribute < Identity
      def initialize(owner:, name:, value:, partitioning: nil, absent_by_name: nil)
        super(
          source: :current_attribute,
          key: "#{owner}.#{name}",
          value: Dependencies.canonical_identity(value),
          metadata: { owner: owner.to_s, name: name.to_s },
          partitioning: partitioning,
          absent_by_name: absent_by_name
        )
      end
    end

    class SessionValue < Identity
      def initialize(key:, value:, partitioning: nil, absent_by_name: nil)
        super(
          source: :session,
          key: key.to_s,
          value: Dependencies.private_fingerprint(value),
          metadata: { key: key.to_s, value_class: value.class.name },
          partitioning: partitioning,
          absent_by_name: absent_by_name
        )
      end
    end

    class CookieValue < Identity
      def initialize(key:, value:, partitioning: nil, absent_by_name: nil)
        super(
          source: :cookie,
          key: key.to_s,
          value: Dependencies.private_fingerprint(value),
          metadata: { key: key.to_s, value_class: value.class.name },
          partitioning: partitioning,
          absent_by_name: absent_by_name
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
      metadata = symbolize_keys(snapshot.fetch(:metadata))

      case source.to_sym
      when :active_record_attribute
        ActiveRecordAttribute.new(
          table: key.fetch(:table),
          id: key.fetch(:id),
          attribute: key.fetch(:attribute),
          model: metadata[:model]
        )
      when :active_record_collection, :active_record_query
        dependency_class = source.to_sym == :active_record_query ? ActiveRecordQuery : ActiveRecordCollection
        dependency_class.new(
          primary_table: metadata.fetch(:primary_table),
          table_columns: metadata.fetch(:table_columns),
          coverage: metadata.fetch(:coverage),
          sql: metadata.fetch(:sql),
          predicates: metadata.fetch(:predicates)
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

    def partitioning_identity?(dependency)
      return false unless dependency.identity?

      flag = metadata_value(dependency, :partitioning_identity)
      return flag if [true, false].include?(flag)

      !nil_identity?(dependency)
    end

    def identity_absent_for?(dependency, name)
      absent_by_name = metadata_value(dependency, :identity_absent_by_name) || {}
      absent_by_name = absent_by_name.transform_keys(&:to_s) if absent_by_name.respond_to?(:transform_keys)
      return absent_by_name.fetch(name.to_s) if absent_by_name.key?(name.to_s)

      !partitioning_identity?(dependency)
    end

    def nil_identity?(dependency)
      dependency.respond_to?(:nil_identity?) && dependency.nil_identity?
    end

    def metadata_value(dependency, key)
      return unless dependency.respond_to?(:metadata)

      if dependency.metadata.key?(key)
        dependency.metadata.fetch(key)
      elsif dependency.metadata.key?(key.to_s)
        dependency.metadata.fetch(key.to_s)
      end
    end

    def private_fingerprint(value)
      Digest::SHA256.hexdigest(JSON.generate(private_fingerprint_payload(value)))[0, 16]
    end

    def private_fingerprint_payload(value)
      case value
      when nil, true, false, Numeric, String
        [value.class.name, value]
      when Symbol
        ["Symbol", value.to_s]
      when Array
        ["Array", value.map { |item| private_fingerprint_payload(item) }]
      when Hash
        entries = value.keys.sort_by { |key| JSON.generate(private_fingerprint_payload(key)) }.map do |key|
          [private_fingerprint_payload(key), private_fingerprint_payload(value.fetch(key))]
        end
        ["Hash", entries]
      else
        identity = model_identity(value)
        identity ? ["Model", identity] : ["Object", value.class.name, value.inspect]
      end
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
