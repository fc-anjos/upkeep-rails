# frozen_string_literal: true

require "active_support/notifications"
require "digest"

module Upkeep
  module Delivery
    class ActionCableAdapter
      STREAM_PREFIX = "upkeep:subscriber"

      def self.stream_name_for(subscriber_id)
        "#{STREAM_PREFIX}:#{Digest::SHA256.hexdigest(subscriber_id.to_s)[0, 32]}"
      end

      def initialize(server: default_server)
        @server = server
      end

      def deliver(envelope)
        stream_name = envelope.stream_name || self.class.stream_name_for(envelope.subscriber_id)
        payload = {
          subscriber_id: envelope.subscriber_id,
          stream_name: stream_name,
          envelope_digest: Transport.envelope_digest(envelope),
          bytesize: envelope.body.bytesize
        }

        ActiveSupport::Notifications.instrument("deliver.upkeep", payload) do
          server.broadcast(stream_name, envelope.body)
        end
      end

      private

      attr_reader :server

      def default_server
        require "action_cable"
        ::ActionCable.server
      end
    end
  end
end
