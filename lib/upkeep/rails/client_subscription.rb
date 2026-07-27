# frozen_string_literal: true

require "cgi"

module Upkeep
  module Rails
    module ClientSubscription
      CHANNEL = "Upkeep::Rails::Cable::Channel"
      ID_HEADER = "X-Upkeep-Subscription-Id"
      TOKEN_HEADER = "X-Upkeep-Subscription-Token"
      CHANNEL_HEADER = "X-Upkeep-Subscription-Channel"
      STREAM_HEADER = "X-Upkeep-Subscription-Stream"
      ACTION_HEADER = "X-Upkeep-Subscription-Action"

      module_function

      def inject(html, identity:, subscription:)
        marker = marker_for(identity: identity, subscription: subscription)
        insert_before_closing("body", html, marker) ||
          "#{html}#{marker}"
      end

      # The payload travels as attributes (like turbo-cable-stream-source), never
      # as text content, so it can't show up as page text when JS is absent.
      def marker_for(identity:, subscription:)
        attributes = payload_for(identity: identity, subscription: subscription).merge(
          "id" => "upkeep-subscription-source"
        )

        [
          %(<upkeep-subscription-source ),
          attributes.map { |name, value| %(#{name}="#{CGI.escapeHTML(value.to_s)}") }.join(" "),
          %( hidden style="display:none" data-upkeep-subscription>),
          %(</upkeep-subscription-source>)
        ].join
      end

      def headers_for(identity:, subscription:)
        payload = payload_for(identity: identity, subscription: subscription)
        {
          ID_HEADER => payload.fetch("subscription-id"),
          TOKEN_HEADER => payload.fetch("activation-token"),
          CHANNEL_HEADER => payload.fetch("channel"),
          STREAM_HEADER => payload.fetch("stream-name")
        }
      end

      def payload_for(identity:, subscription:)
        {
          "channel" => CHANNEL,
          "subscription-id" => subscription.id,
          "activation-token" => ActivationToken.generate(subscription),
          "stream-name" => identity.stream_name
        }
      end

      def insert_before_closing(tag, html, marker)
        index = html.rindex(%(</#{tag}>)) || html.rindex(%(</#{tag.upcase}>))
        return unless index

        "#{html[0...index]}#{marker}#{html[index..]}"
      end
    end
  end
end
