# frozen_string_literal: true

require "active_support/notifications"
require_relative "capture/request"
require_relative "subscriptions/registrar"
require_relative "rails/configuration"
require_relative "rails/activation_token"
require_relative "rails/delivery_job"
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
    REQUEST_CAPTURE = "request_capture.upkeep"
    DELIVERY_ENQUEUE = "delivery_enqueue.upkeep"
    DELIVERY_ENQUEUE_ERROR = "delivery_enqueue_error.upkeep"
    INTERNAL_DELIVERY_TABLES = %w[
      upkeep_subscriptions
      upkeep_subscription_index_entries
    ].freeze

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
        @subscription_shape_cache&.reset
        @subscription_registrar = nil
        discard_subscription_store! if @subscriptions
        @subscriptions = build_subscription_store
        @subscriptions.reset
        @transport = Delivery::BroadcastTransport.new
      end

      def register_controller_subscription(controller, capture)
        recorder = capture.recorder
        return unless subscription_response?(controller, capture)

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
        registration = subscription_registrar.register(
          identity: identity,
          decision: decision,
          recorder: recorder,
          signature: capture.signature,
          metadata: identity_metadata(decision).merge(
            path: controller.request.fullpath,
            stream_name: identity.stream_name
          )
        )
        instrument_subscription_identity(decision, registered: true, subscription: registration.subscription)

        registration
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
        changes = deliverable_changes(changes)
        return Delivery::Transport::DispatchReport.new([]) if changes.empty?

        dispatch_changes(changes)
      rescue StandardError => error
        instrument_delivery_enqueue_error(changes, error)
        Delivery::Transport::DispatchReport.new([])
      end

      def deliver_changes_now!(changes = Runtime::ChangeLog.drain)
        changes = deliverable_changes(changes)
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
        @delivery_dispatcher ||= Delivery::AsyncDispatcher.new(batch_window: configuration.delivery_batch_window) do |change_sets|
          batch = delivery_batch_for(change_sets)
          transport.deliver(batch)
        end
      end

      def dispatch_changes(changes)
        payload = {
          adapter: configuration.delivery_adapter,
          queue: configuration.delivery_queue,
          change_count: changes.size
        }

        ActiveSupport::Notifications.instrument(DELIVERY_ENQUEUE, payload) do
          case configuration.delivery_adapter
          when :active_job
            DeliveryJob.perform_later(changes)
            Delivery::Transport::DispatchReport.new([])
          when :async
            delivery_dispatcher.enqueue(changes)
          when :inline
            deliver_changes_now!(changes)
          end
        end
      end

      def instrument_delivery_enqueue_error(changes, error)
        ActiveSupport::Notifications.instrument(
          DELIVERY_ENQUEUE_ERROR,
          adapter: configuration.delivery_adapter,
          queue: configuration.delivery_queue,
          change_count: changes.size,
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def subscription_registrar
        @subscription_registrar ||= Subscriptions::Registrar.new(
          store: subscriptions,
          shape_cache: subscription_shape_cache
        )
      end

      def subscription_shape_cache
        @subscription_shape_cache ||= Subscriptions::ShapeCache.new
      end

      def delivery_batch_for(change_sets)
        change_sets = compact_change_sets(change_sets)
        return Delivery::TurboStreams::Batch.new([]) if change_sets.empty?

        planner = Invalidation::Planner.new(store: subscriptions)
        plans = change_sets.map { |changes| planner.plan(changes) }
        plans = plans.reject { |plan| plan.targets.empty? }
        return Delivery::TurboStreams::Batch.new([]) if plans.empty?

        Delivery::TurboStreams.new.build_many(plans)
      end

      def compact_change_sets(change_sets)
        change_sets
          .map { |changes| deliverable_changes(changes) }
          .reject(&:empty?)
          .uniq { |changes| change_set_key(changes) }
      end

      def deliverable_changes(changes)
        Array(changes).reject { |change| internal_delivery_change?(change) }
      end

      def internal_delivery_change?(change)
        INTERNAL_DELIVERY_TABLES.include?(change_value(change, :table).to_s)
      end

      def change_set_key(changes)
        changes.map { |change| change_key(change) }.sort
      end

      def change_key(change)
        [
          change_value(change, :type).to_s,
          change_value(change, :table).to_s,
          change_value(change, :model).to_s,
          change_value(change, :id).to_s,
          Array(change_value(change, :changed_attributes)).map(&:to_s).sort,
          change_value(change, :old_values).inspect,
          change_value(change, :new_values).inspect
        ]
      end

      def change_value(change, key)
        return unless change.respond_to?(:[])

        change[key] || change[key.to_s]
      end

      def discard_subscription_store!
        @subscriptions&.shutdown
        @subscriptions = nil
        @subscription_registrar = nil
      end

      def identity_metadata(decision)
        {
          identity_mode: decision.mode,
          anonymous: decision.anonymous,
          anonymous_deopt_reason: decision.deopt_reason,
          identity_sources: decision.identity_sources,
          identity_names: decision.identity_names
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
            identity_sources: decision&.identity_sources,
            identity_names: decision&.identity_names
          }.merge(extra)
        )
      end

      def subscription_response?(controller, capture)
        controller.request.get? &&
          capture.successful? &&
          capture.html_response? &&
          capture.html.include?("</") &&
          capture.recorder.graph.frame_nodes.any?
      end

      def build_subscription_store
        case configuration.subscription_store
        when :active_record
          schema_errors = Subscriptions::ActiveRecordStore.schema_errors(connect: true)
          unless schema_errors.empty?
            raise ConfigurationError,
              active_record_subscription_store_error(schema_errors)
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
        schema_errors = Subscriptions::ActiveRecordStore.schema_errors(connect: true)
        return true if schema_errors.empty?

        raise ConfigurationError, active_record_subscription_store_error(schema_errors, production: true)
      end

      def active_record_subscription_store_error(schema_errors, production: false)
        prefix = if production
          "Upkeep production boot requires compatible upkeep_subscriptions and " \
            "upkeep_subscription_index_entries tables for subscription_store=:active_record."
        else
          "Upkeep subscription_store=:active_record requires compatible upkeep_subscriptions and " \
            "upkeep_subscription_index_entries tables."
        end

        "#{prefix} Schema errors: #{schema_errors.join("; ")}. Run bin/rails generate upkeep:install " \
          "and bin/rails db:migrate, rebuild stale development/test databases, or set " \
          "config.upkeep.subscription_store = :memory in development/test."
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
