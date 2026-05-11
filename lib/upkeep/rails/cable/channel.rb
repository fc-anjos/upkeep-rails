# frozen_string_literal: true

require "action_cable"

module Upkeep
  module Rails
    module Cable
      class Channel < ::ActionCable::Channel::Base
        def subscribed
          @upkeep_identity = SubscriberIdentity.derive(connection)
          stream_from @upkeep_identity.stream_name

          Upkeep::Rails.transport.connect(
            subscriber_id: @upkeep_identity.subscriber_id,
            adapter: Delivery::ActionCableAdapter.new(server: connection.server)
          )
        rescue UnidentifiedSubscriber
          reject
        end

        def unsubscribed
          Upkeep::Rails.transport.disconnect(@upkeep_identity.subscriber_id) if @upkeep_identity
        end
      end
    end
  end
end
