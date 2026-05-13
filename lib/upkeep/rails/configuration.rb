# frozen_string_literal: true

module Upkeep
  module Rails
    class ConfigurationError < StandardError; end

    class Configuration
      SUBSCRIPTION_STORES = [:active_record, :memory].freeze
      REFUSED_BOUNDARY_BEHAVIORS = [:raise, :warn].freeze

      attr_accessor :enabled
      attr_reader :subscription_store

      def initialize
        @enabled = true
        @subscription_store = :active_record
        @refused_boundary_behavior = nil
      end

      def subscription_store=(value)
        value = value.to_sym if value.respond_to?(:to_sym)

        unless SUBSCRIPTION_STORES.include?(value)
          raise ConfigurationError,
            "Unknown Upkeep subscription_store #{value.inspect}; expected one of #{SUBSCRIPTION_STORES.join(", ")}"
        end

        @subscription_store = value
      end

      def refused_boundary_behavior
        @refused_boundary_behavior || default_refused_boundary_behavior
      end

      def refused_boundary_behavior=(value)
        value = value.to_sym if value.respond_to?(:to_sym)

        unless REFUSED_BOUNDARY_BEHAVIORS.include?(value)
          raise ConfigurationError,
            "Unknown Upkeep refused_boundary_behavior #{value.inspect}; expected one of #{REFUSED_BOUNDARY_BEHAVIORS.join(", ")}"
        end

        @refused_boundary_behavior = value
      end

      private

      def default_refused_boundary_behavior
        if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.to_s == "production"
          :warn
        else
          :raise
        end
      end
    end
  end
end
