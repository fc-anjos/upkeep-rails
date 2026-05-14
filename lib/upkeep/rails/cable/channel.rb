# frozen_string_literal: true

require "action_cable"

module Upkeep
  module Rails
    module Cable
      class Channel < ::ActionCable::Channel::Base
        def subscribed
          subscription = Upkeep::Rails.subscriptions.fetch(subscription_id)
          stream_from stream_name_for(subscription)
          shared_stream_names_for(subscription).each { |stream_name| stream_from stream_name }
        rescue KeyError, ActiveRecord::RecordNotFound
          reject
        end

        def unsubscribed
          Upkeep::Rails.subscriptions.unregister(subscription_id) if Upkeep::Rails.subscriptions.respond_to?(:unregister)
        rescue KeyError, ActiveRecord::RecordNotFound
          nil
        end

        private

        def subscription_id
          params.fetch(:subscription_id)
        end

        def stream_name_for(subscription)
          subscription.metadata.fetch(:stream_name)
        end

        def shared_stream_names_for(subscription)
          subscription.metadata.fetch(:shared_stream_names, [])
        end
      end
    end
  end
end
