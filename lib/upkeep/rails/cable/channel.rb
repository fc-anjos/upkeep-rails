# frozen_string_literal: true

require "action_cable"
require "active_support/notifications"

module Upkeep
  module Rails
    module Cable
      class Channel < ::ActionCable::Channel::Base
        SUBSCRIBE_NOTIFICATION = "subscribe_channel.upkeep"

        def subscribed
          if ActiveSupport::Notifications.notifier.listening?(SUBSCRIBE_NOTIFICATION)
            instrumented_subscribe
          else
            subscribe_without_instrumentation
          end
        end

        def unsubscribed
          Upkeep::Rails.subscriptions.unregister(subscription_id)
        rescue KeyError, ActiveRecord::RecordNotFound
          nil
        end

        private

        def instrumented_subscribe
          payload = { subscription_id: safe_subscription_id }
          ActiveSupport::Notifications.instrument(SUBSCRIBE_NOTIFICATION, payload) do
            subscribe_without_instrumentation(payload: payload)
          end
        end

        def subscribe_without_instrumentation(payload: nil)
          id = subscription_id
          payload[:subscription_id] = id if payload
          subscription = measure(payload, :fetch_ms) { Upkeep::Rails.subscriptions.fetch(id) }
          authorized = measure(payload, :authorization_ms) { authorized_subscription?(subscription) }
          unless authorized
            payload[:rejected] = true if payload
            return reject
          end

          measure(payload, :activation_ms) { Upkeep::Rails.subscriptions.activate(id) }
          stream_count = measure(payload, :stream_attach_ms) { attach_streams(subscription) }
          payload[:stream_count] = stream_count if payload
        rescue KeyError, ActiveRecord::RecordNotFound, UnidentifiedSubscriber
          payload[:rejected] = true if payload
          reject
        end

        def attach_streams(subscription)
          stream_from stream_name_for(subscription)
          count = 1
          shared_stream_names_for(subscription).each do |stream_name|
            stream_from stream_name
            count += 1
          end
          count
        end

        def measure(payload, key)
          return yield unless payload

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          yield
        ensure
          payload[key] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(3) if payload && started_at
        end

        def safe_subscription_id
          subscription_id
        rescue KeyError
          nil
        end

        def subscription_id
          params.fetch(:subscription_id)
        end

        def authorized_subscription?(subscription)
          return true if anonymous_public_subscription?(subscription)
          return true unless metadata_value(subscription, :identity_mode)

          SubscriberIdentity.derive_all(connection)
            .any? { |identity| identity.subscriber_id == subscription.subscriber_id }
        end

        def anonymous_public_subscription?(subscription)
          metadata_value(subscription, :identity_mode) == SubscriberIdentity::ANONYMOUS_PUBLIC_MODE
        end

        def stream_name_for(subscription)
          metadata_value(subscription, :stream_name) || subscription.metadata.fetch(:stream_name)
        end

        def shared_stream_names_for(subscription)
          metadata_value(subscription, :shared_stream_names) || []
        end

        def metadata_value(subscription, key)
          subscription.metadata[key] || subscription.metadata[key.to_s]
        end
      end
    end
  end
end
