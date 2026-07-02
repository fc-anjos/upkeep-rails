# frozen_string_literal: true

require "securerandom"
require "active_support/notifications"

module Upkeep
  module Subscriptions
    # Shared pending -> active registry choreography for the in-memory and
    # Active Record stores. Subclasses hold the @pending_registry / @active_registry
    # instances and supply their store-specific tails through the documented hooks.
    class BaseStore
      # Opportunistic trim (Solid Cache/Solid Cable style): every TRIM_EVERY
      # registrations the store deletes at most TRIM_BATCH_LIMIT subscriptions
      # older than the configured subscription TTL. A deterministic counter is
      # used instead of rand so the cadence is reproducible in tests.
      TRIM_EVERY = 100
      TRIM_BATCH_LIMIT = 500
      PRUNE_NOTIFICATION = "prune.upkeep"
      DEFAULT_SUBSCRIPTION_TTL = 24 * 60 * 60

      def touch(id, now: Time.now)
        fetch(id)
        metadata = { "last_seen_at" => now.utc.iso8601 }
        pending_registry.touch(id, metadata: metadata)
        active_registry.touch(id, metadata: metadata)
        after_touch(id, metadata: metadata, now: now)
      end

      def unregister(ids)
        ids = Array(ids)
        before_unregister(ids)
        pending_registry.unregister(ids)
        active_registry.unregister(ids)
        after_unregister(ids)
        ids.size
      end

      def fetch(id)
        active_registry.fetch(id) || pending_registry.fetch(id) || fetch_missing(id)
      end

      def explain(id)
        fetch(id).explain
      end

      private

      # Wrap a unit of work in an optional ActiveSupport notification: when a
      # listener is attached the block runs inside #instrument with the given
      # payload, otherwise it runs with a nil payload and no instrumentation.
      def with_optional_notification(notification, payload)
        if ActiveSupport::Notifications.notifier.listening?(notification)
          ActiveSupport::Notifications.instrument(notification, payload) do
            yield payload
          end
        else
          yield nil
        end
      end

      # Runs one bounded prune batch every TRIM_EVERY registrations. Failures
      # never propagate into the registration path: they are logged and the
      # stale rows stay until the next trim.
      def trim_opportunistically
        @trim_registration_count = (@trim_registration_count || 0) + 1
        return unless (@trim_registration_count % TRIM_EVERY).zero?

        payload = { store: store_label, limit: TRIM_BATCH_LIMIT }
        ActiveSupport::Notifications.instrument(PRUNE_NOTIFICATION, payload) do
          payload[:pruned] = prune_stale!(limit: TRIM_BATCH_LIMIT)
        end
      rescue StandardError => error
        warn_trim_failure(error)
      end

      def warn_trim_failure(error)
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

        ::Rails.logger.warn(
          "Upkeep opportunistic subscription prune failed " \
          "(#{error.class}: #{error.message}); stale subscriptions stay until the next trim"
        )
      end

      def stale_threshold
        Time.now - subscription_ttl
      end

      def subscription_ttl
        if defined?(Upkeep::Rails) && Upkeep::Rails.respond_to?(:configuration)
          Upkeep::Rails.configuration.subscription_ttl
        else
          DEFAULT_SUBSCRIPTION_TTL
        end
      end

      def before_unregister(ids); end

      def after_unregister(ids); end

      def next_subscription_id
        "subscription-#{SecureRandom.uuid}"
      end
    end
  end
end
