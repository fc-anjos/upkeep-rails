# frozen_string_literal: true

require "json"

module Upkeep
  module Subscriptions
    module JsonSnapshot
      VERSION = 2
      VERSION_KEY = "__upkeep_snapshot_version"
      VALUE_KEY = "value"
      SYMBOL_VALUE_KEY = "$sym"
      SYMBOL_KEY_PREFIX = "$sym:"
      STRING_KEY_PREFIX = "$str:"
      JSON_KEY_PREFIX = "$json:"
      RESERVED_STRING_KEYS = [SYMBOL_VALUE_KEY].freeze
      RESERVED_STRING_KEY_PREFIXES = [SYMBOL_KEY_PREFIX, STRING_KEY_PREFIX, JSON_KEY_PREFIX].freeze

      module_function

      def dump(value)
        {
          VERSION_KEY => VERSION,
          VALUE_KEY => encode(value)
        }
      end

      def load(snapshot)
        snapshot = JSON.parse(snapshot) if snapshot.is_a?(String)
        version = snapshot.fetch(VERSION_KEY)
        unless version.to_i == VERSION
          raise ArgumentError, "unsupported Upkeep JSON snapshot version: #{version.inspect}"
        end

        decode(snapshot.fetch(VALUE_KEY))
      end

      def encode(value)
        case value
        when Symbol
          { SYMBOL_VALUE_KEY => value.to_s }
        when Hash
          value.each_with_object({}) { |(key, nested_value), encoded| encoded[encode_key(key)] = encode(nested_value) }
        when Array
          value.map { |nested_value| encode(nested_value) }
        when nil, true, false, Numeric, String
          value
        else
          raise TypeError, "cannot persist #{value.class.name} in an Upkeep JSON snapshot"
        end
      end

      def decode(value)
        case value
        when Hash
          return value.fetch(SYMBOL_VALUE_KEY).to_sym if value.size == 1 && value.key?(SYMBOL_VALUE_KEY)

          value.each_with_object({}) do |(key, nested_value), decoded|
            decoded[decode_key(key)] = decode(nested_value)
          end
        when Array
          value.map { |nested_value| decode(nested_value) }
        else
          value
        end
      end

      def encode_key(key)
        case key
        when Symbol
          "#{SYMBOL_KEY_PREFIX}#{key}"
        when String
          reserved_string_key?(key) ? "#{STRING_KEY_PREFIX}#{key}" : key
        when nil, true, false, Numeric
          "#{JSON_KEY_PREFIX}#{JSON.generate(encode(key))}"
        else
          raise TypeError, "cannot persist #{key.class.name} as an Upkeep JSON snapshot key"
        end
      end

      def decode_key(key)
        if key.start_with?(SYMBOL_KEY_PREFIX)
          key.delete_prefix(SYMBOL_KEY_PREFIX).to_sym
        elsif key.start_with?(STRING_KEY_PREFIX)
          key.delete_prefix(STRING_KEY_PREFIX)
        elsif key.start_with?(JSON_KEY_PREFIX)
          decode(JSON.parse(key.delete_prefix(JSON_KEY_PREFIX)))
        else
          key
        end
      end

      def reserved_string_key?(key)
        RESERVED_STRING_KEYS.include?(key) || RESERVED_STRING_KEY_PREFIXES.any? { |prefix| key.start_with?(prefix) }
      end

    end
  end
end
