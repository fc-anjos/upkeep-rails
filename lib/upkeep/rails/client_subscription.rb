# frozen_string_literal: true

require "cgi"

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

      # The payload travels as attributes (like turbo-cable-stream-source), never
      # as text content, so it can't show up as page text when JS is absent.
      def marker_for(identity:, subscription:)
        attributes = {
          "id" => "upkeep-subscription-source-#{subscription.id}",
          "channel" => CHANNEL,
          "subscription-id" => subscription.id,
          "activation-token" => ActivationToken.generate(subscription),
          "stream-name" => identity.stream_name
        }

        [
          %(<upkeep-subscription-source ),
          attributes.map { |name, value| %(#{name}="#{CGI.escapeHTML(value.to_s)}") }.join(" "),
          %( hidden style="display:none" data-upkeep-subscription data-turbo-temporary>),
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
