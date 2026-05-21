# frozen_string_literal: true

module Upkeep
  module Rails
    module Testing
      def assert_upkeep_subscription_registered(message = nil)
        assert_select "upkeep-subscription-source[data-upkeep-subscription]"
        assert Upkeep::Rails.subscriptions.subscriptions.any?,
          message || "expected Upkeep to register at least one subscription"
      end

      def upkeep_subscription
        Upkeep::Rails.subscriptions.subscriptions.last
      end

      def upkeep_stream_names(subscription = upkeep_subscription)
        raise ArgumentError, "no Upkeep subscription is registered" unless subscription

        ([subscription.metadata.fetch(:stream_name)] + subscription.metadata.fetch(:shared_stream_names, [])).uniq
      end

      def activate_upkeep_subscription!(subscription = upkeep_subscription)
        raise ArgumentError, "no Upkeep subscription is registered" unless subscription

        activated = Upkeep::Rails.subscriptions.activate(subscription.id)
        raise Upkeep::Subscriptions::NotFound, subscription.id unless activated

        subscription
      end

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
    end
  end
end
