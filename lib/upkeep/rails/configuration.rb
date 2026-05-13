# frozen_string_literal: true

module Upkeep
  module Rails
    class ConfigurationError < StandardError; end

    class Configuration
      SUBSCRIPTION_STORES = [:active_record, :memory].freeze

      attr_accessor :enabled
      attr_reader :subscription_store

      def initialize
        @enabled = true
        @subscription_store = :active_record
      end

      def subscription_store=(value)
        value = value.to_sym if value.respond_to?(:to_sym)

        unless SUBSCRIPTION_STORES.include?(value)
          raise ConfigurationError,
            "Unknown Upkeep subscription_store #{value.inspect}; expected one of #{SUBSCRIPTION_STORES.join(", ")}"
        end

        @subscription_store = value
      end
    end
  end
end
