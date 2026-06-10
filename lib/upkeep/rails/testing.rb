# frozen_string_literal: true

module Upkeep
  module Rails
    # Test helpers for asserting the public Upkeep subscription lifecycle from
    # Rails request, integration, and system tests.
    module Testing
      CHANGE_FACTS_THREAD_KEY = :upkeep_rails_testing_change_facts
      @broadcast_capture_mutex = Mutex.new
      @broadcast_captures = []

      class << self
        # Drains the async delivery dispatcher when a test needs deterministic
        # broadcast assertions.
        #
        # Production code should not call this; normal app delivery runs
        # on the in-process dispatcher.
        #
        # @return [void]
        def drain_delivery!
          Upkeep::Rails.send(:drain_delivery_dispatcher!)
        end

        # Captures facts passed into Upkeep delivery while the block runs. This
        # exposes the same committed-change payloads the planner sees, without
        # broadcasting or altering application code.
        #
        # @return [Array(Object, Array<Hash>)] the block result and captured facts.
        def capture_change_facts
          previous = Thread.current[CHANGE_FACTS_THREAD_KEY]
          facts = []
          Thread.current[CHANGE_FACTS_THREAD_KEY] = facts

          [yield, facts]
        ensure
          Thread.current[CHANGE_FACTS_THREAD_KEY] = previous
        end

        # Records delivery facts for capture_change_facts. Internal test hook;
        # production delivery calls this only when a capture is active.
        def record_change_facts(changes)
          facts = Thread.current[CHANGE_FACTS_THREAD_KEY]
          return unless facts

          facts.concat(Array(changes).map { |change| clone_change_fact(change) })
        end

        # @return [Boolean] true when the current thread is capturing change facts.
        def capturing_change_facts?
          !!Thread.current[CHANGE_FACTS_THREAD_KEY]
        end

        # Captures rendered Upkeep delivery payloads while the block runs.
        # This observes the batch after planning/rendering and before the
        # app-specific transport adapter, so tests stay deterministic across
        # ActionCable adapters.
        def capture_broadcasts
          broadcasts = []
          broadcast_capture_mutex.synchronize { broadcast_captures << broadcasts }

          yield
          drain_delivery!
          broadcasts.dup
        ensure
          broadcast_capture_mutex.synchronize { broadcast_captures.delete(broadcasts) } if broadcasts
        end

        # @return [Boolean] true when any thread is capturing delivery batches.
        def capturing_broadcasts?
          broadcast_capture_mutex.synchronize { broadcast_captures.any? }
        end

        # Records a rendered delivery batch for active capture_broadcasts
        # blocks. Internal test hook; production delivery calls this only when
        # a capture is active.
        def record_delivery_batch(batch)
          captures = broadcast_capture_mutex.synchronize { broadcast_captures.dup }
          return if captures.empty?

          bodies = batch.envelopes.map(&:body)
          return if bodies.empty?

          broadcast_capture_mutex.synchronize do
            captures.each do |capture|
              capture.concat(bodies) if broadcast_captures.include?(capture)
            end
          end
        end

        # Runs the invalidation planner against committed-change facts without
        # enqueueing delivery or broadcasting.
        #
        # @param changes [Hash, Array<Hash>] one or more change facts.
        # @param store [#reverse_index] subscription store to inspect.
        # @return [Hash] concise planner match report.
        def match_report(changes, store: Upkeep::Rails.subscriptions)
          changes = changes.is_a?(Hash) ? [changes] : Array(changes)
          lookup_payloads = []
          subscription = ActiveSupport::Notifications.subscribe("lookup_subscription_index.upkeep") do |event|
            lookup_payloads << event.payload.dup
          end

          plan = Upkeep::Invalidation::Planner.new(store: store).plan(changes)

          {
            candidate_entries: plan.candidate_entries.size,
            matched_entries: plan.matched_entries.size,
            miss_reason: match_miss_reason(plan, changes, lookup_payloads),
            targets: plan.targets.map { |target| match_report_target(target) }
          }
        ensure
          ActiveSupport::Notifications.unsubscribe(subscription) if subscription
        end

        private

        attr_reader :broadcast_capture_mutex, :broadcast_captures

        def clone_change_fact(change)
          case change
          when Hash
            change.to_h.transform_values { |value| clone_change_fact(value) }
          when Array
            change.map { |value| clone_change_fact(value) }
          else
            begin
              change.dup
            rescue TypeError
              change
            end
          end
        end

        def match_miss_reason(plan, changes, lookup_payloads)
          return nil if plan.targets.any?
          return "no_changes" if changes.empty?

          lookup_payloads.reverse_each do |payload|
            return payload.fetch(:miss_reason) if payload.key?(:miss_reason)
          end

          return "no_matching_subscriber" if plan.candidate_entries.empty?
          return "dependencies_did_not_match_change" if plan.matched_entries.empty?

          "no_renderable_target"
        end

        def match_report_target(target)
          {
            subscription_id: target.subscription_id,
            subscriber_id: target.subscriber_id,
            subscriber_ids: target.subscriber_ids,
            target: {
              kind: target.target.kind,
              id: target.target.id,
              reason: target.target.reason
            },
            shared_stream_target: {
              kind: target.shared_stream_target.kind,
              id: target.shared_stream_target.id
            },
            frame_id: target.frame_id,
            identity_signature: target.identity_signature,
            action: target.action,
            matched_dependency_keys: target.matched_dependency_keys,
            deoptimization_reason: target.deoptimization_reason
          }
        end
      end

      # Asserts that the last successful HTML response injected an Upkeep
      # subscription marker and registered a subscription in the configured
      # store.
      #
      # @param message [String, nil] optional assertion failure message.
      # @return [void]
      def assert_upkeep_subscription_registered(message = nil)
        assert_select "upkeep-subscription-source[data-upkeep-subscription]"
        assert Upkeep::Rails.subscriptions.subscriptions.any?,
          message || "expected Upkeep to register at least one subscription"
      end

      # Returns the most recently registered Upkeep subscription.
      #
      # @return [Upkeep::Subscriptions::Subscription, nil]
      def upkeep_subscription
        Upkeep::Rails.subscriptions.subscriptions.last
      end

      # Returns every ActionCable stream name that can receive broadcasts for a
      # subscription, including shared streams.
      #
      # @param subscription [Upkeep::Subscriptions::Subscription]
      # @return [Array<String>]
      # @raise [ArgumentError] when no subscription is registered.
      def upkeep_stream_names(subscription = upkeep_subscription)
        raise ArgumentError, "no Upkeep subscription is registered" unless subscription

        ([subscription.metadata.fetch(:stream_name)] + subscription.metadata.fetch(:shared_stream_names, [])).uniq
      end

      # Activates the registered subscription so delivery lookup can find it.
      #
      # @param subscription [Upkeep::Subscriptions::Subscription]
      # @return [Upkeep::Subscriptions::Subscription]
      # @raise [ArgumentError] when no subscription is registered.
      # @raise [Upkeep::Subscriptions::NotFound] when activation fails.
      def activate_upkeep_subscription!(subscription = upkeep_subscription)
        raise ArgumentError, "no Upkeep subscription is registered" unless subscription

        activated = Upkeep::Rails.subscriptions.activate(subscription.id)
        raise Upkeep::Subscriptions::NotFound, subscription.id unless activated

        subscription
      end

      # Captures rendered Upkeep broadcasts while the block runs. This observes
      # Upkeep after planning/rendering and before the application ActionCable
      # adapter, so tests stay deterministic regardless of the host app's cable
      # adapter.
      #
      # @param subscription [Upkeep::Subscriptions::Subscription]
      # @return [Array<String>]
      # @raise [ArgumentError] when called without a block or subscription.
      def capture_upkeep_broadcasts(subscription = upkeep_subscription, &block)
        raise ArgumentError, "capture_upkeep_broadcasts requires a block" unless block
        raise ArgumentError, "no Upkeep subscription is registered" unless subscription

        Upkeep::Rails::Testing.capture_broadcasts(&block)
      end

      # Drains async Upkeep delivery for deterministic test assertions.
      #
      # @return [void]
      def drain_upkeep_delivery!
        Upkeep::Rails::Testing.drain_delivery!
      end

      # Captures facts passed into Upkeep delivery while the block runs.
      #
      # @return [Array(Object, Array<Hash>)] the block result and captured facts.
      def capture_upkeep_change_facts(&block)
        raise ArgumentError, "capture_upkeep_change_facts requires a block" unless block

        Upkeep::Rails::Testing.capture_change_facts(&block)
      end

      # Returns a dry-run invalidation planner report for one or more change
      # facts against the configured Upkeep subscription store.
      #
      # @param changes [Hash, Array<Hash>] one or more change facts.
      # @return [Hash]
      def upkeep_match_report(changes)
        Upkeep::Rails::Testing.match_report(changes)
      end
    end
  end
end
