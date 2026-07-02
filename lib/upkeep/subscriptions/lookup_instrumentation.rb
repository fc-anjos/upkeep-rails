# frozen_string_literal: true

require "active_support/notifications"

module Upkeep
  module Subscriptions
    # Shared lookup instrumentation for the memory and layered reverse indexes:
    # one notification name, one entries_for dispatch, one miss-reason rule.
    # Including classes provide #lookup_store, #entries_for_with_payload and
    # #entries_for_without_payload.
    module LookupInstrumentation
      LOOKUP_NOTIFICATION = "lookup_subscription_index.upkeep"

      def entries_for(changes)
        if ActiveSupport::Notifications.notifier.listening?(LOOKUP_NOTIFICATION)
          payload = { changes: Array(changes).size, store: lookup_store }
          ActiveSupport::Notifications.instrument(LOOKUP_NOTIFICATION, payload) do
            entries_for_with_payload(changes, payload)
          end
        else
          entries_for_without_payload(changes)
        end
      end

      private

      def miss_reason(pending_entries)
        pending_entries.any? ? "not_activated_yet" : "no_matching_subscriber"
      end
    end
  end
end
