# frozen_string_literal: true

require_relative "rails/configuration"
require_relative "rails/action_view_capture"
require_relative "rails/cable"
require_relative "rails/client_subscription"
require_relative "rails/controller_runtime"
require_relative "rails/install"
require_relative "rails/railtie" if defined?(::Rails::Railtie)

module Upkeep
  module Rails
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def subscriptions
        @subscriptions ||= Subscriptions::Store.new
      end

      def transport
        @transport ||= Delivery::Transport.new
      end

      def reset_runtime!
        @subscriptions = Subscriptions::Store.new
        @transport = Delivery::Transport.new
      end

      def register_controller_subscription(controller, recorder)
        return unless subscription_response?(controller, recorder)

        identity = Cable::SubscriberIdentity.derive_from_request(controller.request, recorder: recorder)
        subscription = subscriptions.register(
          subscriber_id: identity.subscriber_id,
          recorder: recorder,
          metadata: {
            path: controller.request.fullpath,
            stream_name: identity.stream_name
          }
        )

        controller.response.body = ClientSubscription.inject(
          controller.response.body,
          identity: identity,
          subscription: subscription
        )

        subscription
      rescue Cable::UnidentifiedSubscriber
        nil
      end

      def deliver_changes!(changes = Runtime::ChangeLog.drain)
        changes = Array(changes)
        return Delivery::Transport::DispatchReport.new([]) if changes.empty?

        plan = Invalidation::Planner.new(store: subscriptions).plan(changes)
        batch = Delivery::TurboStreams.new.build(plan)
        transport.deliver(batch)
      end

      private

      def subscription_response?(controller, recorder)
        controller.request.get? &&
          controller.response.successful? &&
          controller.response.media_type == "text/html" &&
          controller.response.body.to_s.include?("</") &&
          recorder.graph.frame_nodes.any?
      end
    end
  end
end
