# frozen_string_literal: true

module Upkeep
  module Rails
    class ConfigurationError < StandardError; end

    class Configuration
      SUBSCRIPTION_STORES = [:active_record, :memory].freeze
      REFUSED_BOUNDARY_BEHAVIORS = [:raise, :warn].freeze
      IDENTITY_SOURCES = [:current, :session, :cookie, :warden].freeze

      class IdentityDefinition
        attr_reader :name, :source, :source_key, :subscribe_block

        def initialize(name:, source:, source_key:, subscribe_block:, absent_block: nil)
          @name = name.to_sym
          @source = source.to_sym
          @source_key = source_key
          @subscribe_block = subscribe_block
          @absent_block = absent_block
        end

        def matches_dependency?(dependency)
          case source
          when :current
            dependency.source == :current_attribute &&
              metadata_value(dependency, :owner) == source_key.fetch(:owner) &&
              metadata_value(dependency, :name) == source_key.fetch(:name)
          when :session
            dependency.source == :session && metadata_value(dependency, :key) == source_key
          when :cookie
            dependency.source == :cookie && metadata_value(dependency, :key) == source_key
          when :warden
            dependency.source == :warden_user && metadata_value(dependency, :scope) == source_key
          else
            false
          end
        end

        def matches_source?(source, key)
          source = source.to_sym

          case self.source
          when :current
            source == :current &&
              key.fetch(:owner).to_s == source_key.fetch(:owner) &&
              key.fetch(:name).to_s == source_key.fetch(:name)
          when :session, :cookie, :warden
            source == self.source && key.to_s == source_key
          else
            false
          end
        end

        def absent?(value)
          return value.nil? unless @absent_block

          @absent_block.arity == 1 ? @absent_block.call(value) : @absent_block.call
        end

        def absent_dependency?(dependency)
          Upkeep::Dependencies.identity_absent_for?(dependency, name)
        end

        def source_label
          case source
          when :current
            "#{source_key.fetch(:owner)}.#{source_key.fetch(:name)}"
          when :session
            "session[:#{source_key}]"
          when :cookie
            "cookies[:#{source_key}]"
          when :warden
            "warden.user(:#{source_key})"
          end
        end

        private

        def metadata_value(dependency, key)
          value = dependency.metadata[key] || dependency.metadata[key.to_s]
          value.to_s
        end
      end

      class IdentityBuilder
        attr_reader :subscribe_block, :absent_block

        def absent_if(&block)
          @absent_block = block
        end

        def subscribe(&block)
          @subscribe_block = block
        end
      end

      attr_accessor :enabled
      attr_accessor :activation_token_expires_in
      attr_accessor :delivery_batch_window
      # Test/console hook: deliver changes synchronously in the caller instead
      # of on the in-process background dispatcher.
      attr_accessor :deliver_inline
      attr_reader :subscription_store

      def initialize
        @enabled = true
        @subscription_store = :active_record
        @deliver_inline = false
        @delivery_batch_window = 0.01
        @refused_boundary_behavior = nil
        @activation_token_expires_in = 24 * 60 * 60
        @identity_definitions = {}
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

      def identify(name, current: nil, session: nil, cookie: nil, warden: nil, &block)
        source, source_key = identity_source(current: current, session: session, cookie: cookie, warden: warden)
        builder = IdentityBuilder.new
        if block
          block.arity == 1 ? block.call(builder) : builder.instance_eval(&block)
        end

        unless builder.subscribe_block
          raise ConfigurationError, "config.identify :#{name} requires a subscribe block"
        end

        @identity_definitions[name.to_sym] = IdentityDefinition.new(
          name: name,
          source: source,
          source_key: source_key,
          subscribe_block: builder.subscribe_block,
          absent_block: builder.absent_block
        )
      end

      def identity_presence_metadata(source:, key:, value:)
        definitions = identity_definitions.select { |definition| definition.matches_source?(source, key) }
        absent_by_name = definitions.to_h do |definition|
          [definition.name.to_s, definition.absent?(value)]
        end

        {
          partitioning: if definitions.any?
            absent_by_name.values.any? { |absent| !absent }
          else
            !value.nil?
          end,
          absent_by_name: absent_by_name
        }
      end

      def identity_definitions
        @identity_definitions.values
      end

      def identity_definition(name)
        @identity_definitions.fetch(name.to_sym)
      end

      def clear_identities!
        @identity_definitions.clear
      end

      private

      def identity_source(current:, session:, cookie:, warden:)
        sources = {
          current: current,
          session: session,
          cookie: cookie,
          warden: warden
        }.compact

        unless sources.size == 1
          raise ConfigurationError,
            "config.identify requires exactly one source: #{IDENTITY_SOURCES.join(", ")}"
        end

        source, value = sources.first
        [source, normalize_identity_source(source, value)]
      end

      def normalize_identity_source(source, value)
        case source
        when :current
          owner, name = Array(value)
          unless owner && name
            raise ConfigurationError,
              "config.identify current: expects [CurrentClass, :attribute]"
          end

          { owner: owner.to_s, name: name.to_s }
        when :session, :cookie, :warden
          value.to_s
        end
      end

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
