# frozen_string_literal: true

require "action_cable"

module Upkeep
  module Rails
    module Cable
      class Channel < ::ActionCable::Channel::Base
        def subscribed
          @upkeep_identities = SubscriberIdentity.derive_all(connection)
          @upkeep_identities.each { |identity| stream_from identity.stream_name }
        rescue UnidentifiedSubscriber
          reject
        end
      end
    end
  end
end
