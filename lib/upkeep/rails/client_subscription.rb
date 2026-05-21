# frozen_string_literal: true

require "cgi"
require "json"

module Upkeep
  module Rails
    module ClientSubscription
      CHANNEL = "Upkeep::Rails::Cable::Channel"

      module_function

      def inject(html, identity:, subscription:)
        marker = marker_for(identity: identity, subscription: subscription)
        insert_before_closing("body", html, marker) ||
          "#{html}#{marker}"
      end

      def marker_for(identity:, subscription:)
        payload = JSON.generate(
          channel: CHANNEL,
          subscription_id: subscription.id,
          activation_token: ActivationToken.generate(subscription),
          stream_name: identity.stream_name
        ).gsub("</", '<\/')

        id = "upkeep-subscription-source-#{subscription.id}"

        [
          %(<upkeep-subscription-source id="#{CGI.escapeHTML(id)}" ),
          %(data-upkeep-subscription data-turbo-temporary>),
          CGI.escapeHTML(payload),
          %(</upkeep-subscription-source>)
        ].join
      end

      def insert_before_closing(tag, html, marker)
        index = html.rindex(%(</#{tag}>)) || html.rindex(%(</#{tag.upcase}>))
        return unless index

        "#{html[0...index]}#{marker}#{html[index..]}"
      end
    end
  end
end
