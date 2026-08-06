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
  end
end
