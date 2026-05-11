# frozen_string_literal: true

require "action_cable"

module Upkeep
  module Rails
    module Cable
      class Channel < ::ActionCable::Channel::Base
        def subscribed
          @upkeep_identities = SubscriberIdentity.derive_all(connection)

          @upkeep_identities.each do |identity|
            stream_from identity.stream_name

            Upkeep::Rails.transport.connect(
              subscriber_id: identity.subscriber_id,
              adapter: Delivery::ActionCableAdapter.new(server: connection.server)
            )
          end
        rescue UnidentifiedSubscriber
          reject
        end

        def unsubscribed
          Array(@upkeep_identities).each { |identity| Upkeep::Rails.transport.disconnect(identity.subscriber_id) }
        end
      end
    end
  end
end
