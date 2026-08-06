module RefreshSync
  # Fail-closed must be observable: Tier S degrades to Tier P silently by
  # design, so a broken scrubbed renderer looks like conservatism, not like
  # a bug (this exact failure shipped in phase 2 as the reset_all incident).
  # Health turns the instrumentation stream into a dead-feature signal.
  class Health
    EVENTS = %w[
      surface_observed surface_promoted surface_pinned surface_demoted
      surface_broadcast_sent scrubbed_render_failed
    ].freeze

    attr_reader :counters, :pin_reasons

    def initialize
      @counters = Hash.new(0)
      @pin_reasons = Hash.new(0)
      @subscribers = EVENTS.map do |event|
        ActiveSupport::Notifications.subscribe("#{event}.refresh_sync") do |*_args, payload|
          @counters[event.to_sym] += 1
          @pin_reasons[payload[:reason]] += 1 if payload[:reason]
        end
      end
    end

    def detach!
      @subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
    end

    # The signal that would have caught the dead-feature bug: scrubbed
    # renders keep failing and nothing ever promotes.
    def tier_s_dead?
      @counters[:scrubbed_render_failed] >= 2 && @counters[:surface_promoted].zero?
    end

    # Boot-time cable topology check (good citizens: we use whatever cable
    # adapter the app uses and NEVER rewrite its config — but a topology
    # that cannot deliver must say so loudly instead of silently dropping
    # cross-process updates). The async adapter is per-process: with more
    # than one server process (cluster-mode Puma via WEB_CONCURRENCY, or
    # any multi-machine deploy), a write handled in one process can never
    # reach a subscriber connected to another.
    def self.check_cable_topology!(adapter: nil, web_concurrency: ENV["WEB_CONCURRENCY"], logger: nil)
      adapter ||=
        if defined?(::ActionCable) && ::ActionCable.server.config.cable
          ::ActionCable.server.config.cable["adapter"] || ::ActionCable.server.config.cable[:adapter]
        end
      return :ok unless adapter.to_s == "async"

      workers = web_concurrency.to_i
      verdict = workers > 1 ? :broken : :single_process_only
      message =
        if verdict == :broken
          "RefreshSync: the async Action Cable adapter cannot deliver across " \
          "processes, and WEB_CONCURRENCY=#{workers} runs a multi-process server — " \
          "updates WILL be silently lost between workers. Use a cross-process " \
          "adapter (solid_cable, redis, postgresql) in config/cable.yml."
        else
          "RefreshSync: the async Action Cable adapter is per-process; " \
          "deliveries will not cross processes. Fine for a single-process " \
          "server, broken the moment a second process appears."
        end
      (logger || (defined?(::Rails) && ::Rails.logger))&.warn(message)
      ActiveSupport::Notifications.instrument(
        "cable_topology.refresh_sync", adapter: adapter.to_s, verdict: verdict,
        web_concurrency: workers
      )
      RefreshSync.stats[:cable_topology_warnings] += 1
      verdict
    end
  end
end
