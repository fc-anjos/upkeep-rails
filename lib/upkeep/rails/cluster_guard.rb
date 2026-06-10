# frozen_string_literal: true

module Upkeep
  module Rails
    # Detects boot configurations where live updates silently break across
    # cluster workers: an in-process cable adapter or an in-memory
    # subscription store cannot reach browsers or subscriptions held by
    # another process.
    class ClusterGuard
      IN_PROCESS_CABLE_ADAPTERS = %w[async].freeze

      attr_reader :cable_adapter, :worker_count, :subscription_store, :environment

      def initialize(cable_adapter:, worker_count:, subscription_store:, environment:)
        @cable_adapter = cable_adapter.to_s
        @worker_count = worker_count.to_i
        @subscription_store = subscription_store&.to_sym
        @environment = environment.to_s
      end

      def clustered?
        worker_count.positive?
      end

      def problems
        return [] unless clustered?

        problems = []
        if IN_PROCESS_CABLE_ADAPTERS.include?(cable_adapter)
          problems << "the #{cable_adapter} Action Cable adapter is in-process, so broadcasts from one worker " \
            "never reach sockets held by another; configure a cross-process cable adapter such as solid_cable " \
            "or redis in config/cable.yml"
        end
        if subscription_store == :memory
          problems << "subscription_store=:memory is per-process, so subscriptions registered in one worker are " \
            "invisible to the others; set config.upkeep.subscription_store = :active_record"
        end
        problems
      end

      def error?
        problems.any? && environment == "production"
      end

      def warning?
        problems.any? && !error?
      end

      def message
        return if problems.empty?

        "Upkeep detected a clustered server (#{worker_count} workers) with a configuration that cannot " \
          "deliver live updates across processes: #{problems.join("; ")}."
      end
    end
  end
end
