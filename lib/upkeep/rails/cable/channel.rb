# frozen_string_literal: true

require "action_cable"

module Upkeep
  module Rails
    module Cable
      class Channel < ::ActionCable::Channel::Base
        def subscribed
          subscription = Upkeep::Rails.subscriptions.fetch(subscription_id)
          return reject unless authorized_subscription?(subscription)

          Upkeep::Rails.subscriptions.activate(subscription_id)
          stream_from stream_name_for(subscription)
          shared_stream_names_for(subscription).each { |stream_name| stream_from stream_name }
        rescue KeyError, ActiveRecord::RecordNotFound, UnidentifiedSubscriber
          reject
        end

        def unsubscribed
          Upkeep::Rails.subscriptions.unregister(subscription_id)
        rescue KeyError, ActiveRecord::RecordNotFound
          nil
        end

        private

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
