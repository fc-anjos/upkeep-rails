# frozen_string_literal: true

require "active_support/notifications"

module Upkeep
  module Subscriptions
    class LayeredReverseIndex
      LOOKUP_NOTIFICATION = "lookup_subscription_index.upkeep"

      def initialize(active_index:, persistent_index:, persistent_count:, store:, pending_index: nil)
        @active_index = active_index
        @persistent_index = persistent_index
        @persistent_count = persistent_count
        @store = store
        @pending_index = pending_index
      end

      def entries_for(changes)
        if ActiveSupport::Notifications.notifier.listening?(LOOKUP_NOTIFICATION)
          payload = { changes: Array(changes).size, store: store }
          ActiveSupport::Notifications.instrument(LOOKUP_NOTIFICATION, payload) do
            entries_for_with_payload(changes, payload)
          end
        else
          entries_for_without_payload(changes)
        end
      end

      def entries_for_without_payload(changes)
        active_entries = active_index.entries_for(changes)
        return persistent_index.entries_for(changes) if active_index.count.zero?
        return active_entries if active_index.covers?(persistent_subscription_count)

        merge_entries(active_entries, persistent_index.entries_for(changes))
      end

      def entries_for_with_payload(changes, payload)
        active_entries = active_index.entries_for(changes)
        active_count = active_index.count
        pending_entries = pending_entries_for(changes)
        pending_count = pending_count_for_payload
        payload[:active_entries] = active_entries.size
        payload[:active_subscriptions] = active_count
        payload[:pending_entries] = pending_entries.size
        payload[:pending_subscriptions] = pending_count

        if active_count.zero?
          persistent_entries = persistent_index.entries_for(changes)
          payload[:mode] = persistent_entries.empty? && pending_entries.any? ? "pending_activation" : "persistent"
          payload[:persistent_entries] = persistent_entries.size
          apply_miss_reason(payload, active_entries: active_entries, persistent_entries: persistent_entries, pending_entries: pending_entries)
          return persistent_entries
        end

        if active_index.covers?(persistent_subscription_count)
          payload[:mode] = "active"
          payload[:persistent_entries] = 0
          apply_miss_reason(payload, active_entries: active_entries, persistent_entries: [], pending_entries: pending_entries)
          return active_entries
        end

        persistent_entries = persistent_index.entries_for(changes)
        payload[:mode] = "active_and_persistent"
        payload[:persistent_entries] = persistent_entries.size
        apply_miss_reason(payload, active_entries: active_entries, persistent_entries: persistent_entries, pending_entries: pending_entries)
        merge_entries(active_entries, persistent_entries)
      end

      def summary
        persistent = persistent_index.summary
        active = active_index.summary
        pending = pending_index&.summary || { lookup_keys: 0, entries: 0, subscriptions: 0 }
        mode = active_index.covers?(persistent_subscription_count) ? :active : :active_and_persistent
        totals = if mode == :active
          active
        else
          {
            lookup_keys: active.fetch(:lookup_keys) + persistent.fetch(:lookup_keys),
            entries: active.fetch(:entries) + persistent.fetch(:entries)
          }
        end

        {
          lookup_keys: totals.fetch(:lookup_keys),
          entries: totals.fetch(:entries),
          mode: mode,
          active: active,
          pending: pending,
          persistent: persistent
        }
      end

      private

      attr_reader :active_index, :persistent_index, :persistent_count, :store, :pending_index

      def persistent_subscription_count
        persistent_count.call
      end

      def merge_entries(active_entries, persistent_entries)
        (active_entries + persistent_entries).uniq do |entry|
          [entry.subscription_id, entry.owner_id, entry.dependency_cache_key]
        end
      end

      def pending_entries_for(changes)
        pending_index ? pending_index.entries_for(changes) : []
      end

      def pending_count_for_payload
        pending_index&.count || 0
      end

      def apply_miss_reason(payload, active_entries:, persistent_entries:, pending_entries:)
        return if active_entries.any? || persistent_entries.any?

        payload[:miss_reason] = pending_entries.any? ? "not_activated_yet" : "no_matching_subscriber"
      end
    end
  end
end
