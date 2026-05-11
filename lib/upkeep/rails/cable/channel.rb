# frozen_string_literal: true

require "action_cable"

module Upkeep
  module Rails
    module Cable
      class Channel < ::ActionCable::Channel::Base
        def subscribed
          subscription = Upkeep::Rails.subscriptions.fetch(subscription_id)
          stream_from stream_name_for(subscription)
        rescue KeyError, ActiveRecord::RecordNotFound
          reject
        end

        private

        def subscription_id
          params.fetch(:subscription_id)
        end

        def stream_name_for(subscription)
          subscription.metadata.fetch(:stream_name)
        end
      end
    end
  end
end
