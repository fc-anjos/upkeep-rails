# frozen_string_literal: true

module Upkeep
  module Rails
    # Test helpers for asserting the public Upkeep subscription lifecycle from
    # Rails request, integration, and system tests.
    module Testing
      class << self
        # Drains the async delivery dispatcher when a test needs deterministic
        # broadcast assertions.
        #
        # Production code should not call this; normal app delivery runs
        # through the configured adapter.
        #
        # @return [void]
        def drain_delivery!
          Upkeep::Rails.send(:drain_delivery_dispatcher!)
        end
      end

      # Asserts that the last successful HTML response injected an Upkeep
      # subscription marker and registered a subscription in the configured
      # store.
      #
      # @param message [String, nil] optional assertion failure message.
      # @return [void]
      def assert_upkeep_subscription_registered(message = nil)
        assert_select "upkeep-subscription-source[data-upkeep-subscription]"
        assert Upkeep::Rails.subscriptions.subscriptions.any?,
          message || "expected Upkeep to register at least one subscription"
      end

      # Returns the most recently registered Upkeep subscription.
      #
      # @return [Upkeep::Subscriptions::Subscription, nil]
      def upkeep_subscription
        Upkeep::Rails.subscriptions.subscriptions.last
      end

      # Returns every ActionCable stream name that can receive broadcasts for a
      # subscription, including shared streams.
      #
      # @param subscription [Upkeep::Subscriptions::Subscription]
      # @return [Array<String>]
      # @raise [ArgumentError] when no subscription is registered.
      def upkeep_stream_names(subscription = upkeep_subscription)
        raise ArgumentError, "no Upkeep subscription is registered" unless subscription

        ([subscription.metadata.fetch(:stream_name)] + subscription.metadata.fetch(:shared_stream_names, [])).uniq
      end

      # Activates the registered subscription so delivery lookup can find it.
      #
      # @param subscription [Upkeep::Subscriptions::Subscription]
      # @return [Upkeep::Subscriptions::Subscription]
      # @raise [ArgumentError] when no subscription is registered.
      # @raise [Upkeep::Subscriptions::NotFound] when activation fails.
      def activate_upkeep_subscription!(subscription = upkeep_subscription)
        raise ArgumentError, "no Upkeep subscription is registered" unless subscription

        activated = Upkeep::Rails.subscriptions.activate(subscription.id)
        raise Upkeep::Subscriptions::NotFound, subscription.id unless activated

        subscription
      end

      # Captures ActionCable broadcasts for every stream associated with a
      # subscription while the block runs.
      #
      # Include ActionCable::TestHelper before calling this helper.
      #
      # @param subscription [Upkeep::Subscriptions::Subscription]
      # @return [Array<String>]
      # @raise [ArgumentError] when called without a block or subscription.
      # @raise [NoMethodError] when ActionCable::TestHelper is not included.
      def capture_upkeep_broadcasts(subscription = upkeep_subscription, &block)
        raise ArgumentError, "capture_upkeep_broadcasts requires a block" unless block
        raise NoMethodError, "include ActionCable::TestHelper before calling capture_upkeep_broadcasts" unless respond_to?(:capture_broadcasts)

        captures = {}
        nested = upkeep_stream_names(subscription).reverse_each.reduce(block) do |inner, stream_name|
          proc { captures[stream_name] = capture_broadcasts(stream_name, &inner) }
        end

        nested.call
        captures.values.flatten
      end

      # Drains async Upkeep delivery for deterministic test assertions.
      #
      # @return [void]
      def drain_upkeep_delivery!
        Upkeep::Rails::Testing.drain_delivery!
      end
    end
  end
end
