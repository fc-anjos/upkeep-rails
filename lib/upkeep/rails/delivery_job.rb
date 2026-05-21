# frozen_string_literal: true

require "active_job"

module Upkeep
  module Rails
    class DeliveryJob < ::ActiveJob::Base
      queue_as { Upkeep::Rails.configuration.delivery_queue }

      def perform(changes)
        Upkeep::Rails.deliver_changes_now!(normalize_changes(changes))
      end

      private

      def normalize_changes(changes)
        Array(changes).map { |change| normalize_change(change) }
      end

      def normalize_change(change)
        return change unless change.respond_to?(:to_h)

        change.to_h.transform_keys do |key|
          key.respond_to?(:to_sym) ? key.to_sym : key
        end
      end
    end
  end
end
