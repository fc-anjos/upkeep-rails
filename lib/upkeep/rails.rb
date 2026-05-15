# frozen_string_literal: true

require "active_support/notifications"
require_relative "rails/configuration"
require_relative "rails/replay"
require_relative "rails/action_view_capture"
require_relative "rails/cable"
require_relative "rails/client_subscription"
require_relative "rails/controller_runtime"
require_relative "rails/install"
require_relative "rails/testing"
require_relative "rails/railtie" if defined?(::Rails::Railtie)

module Upkeep
  module Rails
    SUBSCRIPTION_IDENTITY = "upkeep.subscription_identity"

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def subscriptions
        discard_subscription_store! if @subscriptions && subscription_store_config_changed?
        @subscriptions ||= build_subscription_store
      end

      def transport
        @transport ||= Delivery::BroadcastTransport.new
      end

      def reset_runtime!
        @delivery_dispatcher&.shutdown
        @delivery_dispatcher = nil
        discard_subscription_store! if @subscriptions
        @subscriptions = build_subscription_store
        @subscriptions.reset
        @transport = Delivery::BroadcastTransport.new
      end

      def register_controller_subscription(controller, recorder)
        html = response_body_html(controller.response.body)
        return unless subscription_response?(controller, recorder, html)

        decision = Cable::SubscriberIdentity.decision_for(controller.request, recorder: recorder)
        unless recorder.reactive?
          instrument_subscription_identity(
            decision,
            registered: false,
            deopt_reason: "refused_boundary",
            refused_boundaries: recorder.refused_boundaries.map(&:reason)
          )
          return
        end

        identity = Cable::SubscriberIdentity.derive_from_request(
          controller.request,
          recorder: recorder,
          decision: decision
        )
        subscription = subscriptions.register(
          subscriber_id: identity.subscriber_id,
          recorder: recorder,
          metadata: identity_metadata(decision).merge(
            path: controller.request.fullpath,
            stream_name: identity.stream_name,
            shared_stream_names: SharedStreams.names_for_recorder(recorder)
          )
        )
        instrument_subscription_identity(decision, registered: true, subscription: subscription)

        controller.response.body = ClientSubscription.inject(
          html,
          identity: identity,
          subscription: subscription
        )

        subscription
      rescue Cable::UnidentifiedSubscriber => error
        instrument_subscription_identity(
          decision || Cable::SubscriberIdentity.decision_for(controller.request, recorder: recorder),
          registered: false,
          deopt_reason: "unidentified_identity",
          error: error.message
        )
        nil
      end

      def deliver_changes!(changes = Runtime::ChangeLog.drain)
        changes = Array(changes)
        return Delivery::Transport::DispatchReport.new([]) if changes.empty?

        delivery_dispatcher.enqueue(changes)
      end

      def deliver_changes_now!(changes = Runtime::ChangeLog.drain)
        changes = Array(changes)
        return Delivery::Transport::DispatchReport.new([]) if changes.empty?

        batch = delivery_batch_for([changes])
        transport.deliver(batch)
      end

      def drain_delivery!
        @delivery_dispatcher&.drain
      end

      def validate_configuration!(environment: rails_environment)
        return true unless configuration.enabled

        validate_subscription_store!(environment: environment)
        true
      end

      private

      def delivery_dispatcher
        @delivery_dispatcher ||= Delivery::AsyncDispatcher.new do |change_sets|
          batch = delivery_batch_for(change_sets)
          transport.deliver(batch)
        end
      end

      def delivery_batch_for(change_sets)
        planner = Invalidation::Planner.new(store: subscriptions)
        plans = change_sets.map { |changes| planner.plan(changes) }
        Delivery::TurboStreams.new.build_many(plans)
      end

      def discard_subscription_store!
        @subscriptions&.shutdown
        @subscriptions = nil
      end

      def identity_metadata(decision)
        {
          identity_mode: decision.mode,
          anonymous: decision.anonymous,
          anonymous_deopt_reason: decision.deopt_reason,
          identity_sources: decision.identity_sources
        }.compact
      end

      def instrument_subscription_identity(decision, registered:, subscription: nil, deopt_reason: nil, **extra)
        ActiveSupport::Notifications.instrument(
          SUBSCRIPTION_IDENTITY,
          {
            registered: registered,
            subscription_id: subscription&.id,
            subscriber_id: subscription&.subscriber_id,
            identity_mode: decision&.mode,
            anonymous: decision&.anonymous,
            anonymous_deopt_reason: deopt_reason || decision&.deopt_reason,
            identity_sources: decision&.identity_sources
          }.merge(extra)
        )
      end

      def subscription_response?(controller, recorder, html)
        controller.request.get? &&
          controller.response.successful? &&
          html_response?(controller) &&
          html.include?("</") &&
          recorder.graph.frame_nodes.any?
      end

      def html_response?(controller)
        controller.response.media_type == "text/html" ||
          controller.response.content_type.to_s.start_with?("text/html")
      end

      def response_body_html(body)
        case body
        when String
          body
        when Array
          body.join
        else
          return body.body.join if body.respond_to?(:body) && body.body.respond_to?(:join)
          return body.to_a.join if body.respond_to?(:to_a)

          body.to_s
        end
      end

      def build_subscription_store
        case configuration.subscription_store
        when :active_record
          unless Subscriptions::ActiveRecordStore.available?(connect: true)
            raise ConfigurationError,
              "Upkeep subscription_store=:active_record requires the upkeep_subscriptions and " \
              "upkeep_subscription_index_entries tables. Run bin/rails generate upkeep:install " \
              "and bin/rails db:migrate, or set config.upkeep.subscription_store = :memory in development/test."
          end

          Subscriptions::ActiveRecordStore.new
        when :memory
          Subscriptions::Store.new
        end.tap do
          @subscription_store_name = configuration.subscription_store
        end
      end

      def validate_subscription_store!(environment:)
        if production_environment?(environment) && configuration.subscription_store == :memory
          raise ConfigurationError,
            "Upkeep subscription_store=:memory is only for development/test; production requires :active_record."
        end

        return true unless production_environment?(environment)
        return true unless configuration.subscription_store == :active_record
        return true if Subscriptions::ActiveRecordStore.available?(connect: true)

        raise ConfigurationError,
          "Upkeep production boot requires the upkeep_subscriptions and " \
          "upkeep_subscription_index_entries tables for subscription_store=:active_record."
      end

      def production_environment?(environment)
        environment.to_s == "production"
      end

      def rails_environment
        ::Rails.env if defined?(::Rails) && ::Rails.respond_to?(:env)
      end

      def subscription_store_config_changed?
        @subscription_store_name != configuration.subscription_store
      end
    end
  end
end
