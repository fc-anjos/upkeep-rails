# frozen_string_literal: true

require "active_support/message_verifier"
require "securerandom"

module Upkeep
  module Rails
    module ActivationToken
      PURPOSE = "upkeep-subscription-activation"

      module_function

      def generate(subscription)
        subscription_id = subscription.respond_to?(:id) ? subscription.id : subscription
        verifier.generate(
          { "subscription_id" => subscription_id.to_s },
          purpose: PURPOSE,
          expires_in: Upkeep::Rails.configuration.activation_token_expires_in
        )
      end

      def valid_for_subscription?(token, subscription_id)
        payload = verifier.verified(token.to_s, purpose: PURPOSE)
        token_subscription_id(payload) == subscription_id.to_s
      end

      def token_subscription_id(payload)
        return unless payload.respond_to?(:[])

        payload["subscription_id"] || payload[:subscription_id]
      end

      def verifier
        rails_message_verifier || fallback_verifier
      end

      def rails_message_verifier
        return unless defined?(::Rails) && ::Rails.respond_to?(:application)
        return unless ::Rails.application.respond_to?(:message_verifier)

        ::Rails.application.message_verifier(PURPOSE)
      rescue StandardError
        nil
      end

      def fallback_verifier
        @fallback_verifier ||= ActiveSupport::MessageVerifier.new(fallback_secret)
      end

      def fallback_secret
        @fallback_secret ||= SecureRandom.hex(64)
      end
    end
  end
end
