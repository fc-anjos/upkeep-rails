require_relative "test_helper"

# Fail-closed must be observable. This suite recreates the phase-2
# dead-feature incident (scrubbed renders always raise -> Tier S silently
# never engages) and asserts the instrumentation surfaces it.
class HealthTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def collect_events
    events = []
    sub = ActiveSupport::Notifications.subscribe(/\.refresh_sync\z/) do |name, *_args, payload|
      events << [name.sub(".refresh_sync", ""), payload]
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def test_lifecycle_events_are_emitted
    events = collect_events do
      a = session_for(@alice)
      c = session_for(@carol)
      a.get "/shared_board"
      c.get "/shared_board"
      Card.create!(board: @board1, title: "Instrumented", status: "open")
      drain_debounce
    end

    names = events.map(&:first)
    assert_includes names, "surface_observed"
    assert_includes names, "surface_promoted"
    assert_includes names, "surface_broadcast_sent"

    pin_events = collect_events do
      session_for(@alice).get "/dashboard"
    end
    pin = pin_events.find { |n, _| n == "surface_pinned" }
    assert pin, "pinning emits an event"
    assert_equal :identity_predicate, pin[1][:reason]
  end

  def test_dead_tier_s_is_visible_through_health
    health = RefreshSync::Health.new
    RefreshSync.renderer_class = Class.new(ActionController::Base) # every scrubbed render raises

    begin
      # Three separate surfaces, each with fully eligible promotion evidence.
      %w[/shared_board /flagged /vip].each do |path|
        session_for(@alice).get path
        session_for(@carol).get path
      end

      assert_operator health.counters[:scrubbed_render_failed], :>=, 3
      assert_equal 0, health.counters[:surface_promoted]
      assert health.tier_s_dead?,
        "eligible surfaces keep failing scrubbed render and nothing promotes: the dead-feature signal fires"
      assert_operator health.pin_reasons.keys.grep(/scrubbed_render_error/).size, :>=, 1
    ensure
      RefreshSync.renderer_class = ScrubbedController
      health.detach!
    end
  end

  def test_healthy_system_does_not_report_dead
    health = RefreshSync::Health.new
    begin
      session_for(@alice).get "/shared_board"
      session_for(@carol).get "/shared_board"
      refute health.tier_s_dead?
      assert_equal 1, health.counters[:surface_promoted]
    ensure
      health.detach!
    end
  end
end

class CableTopologyTest < ActiveSupport::TestCase
  def capture_warns
    logger = Struct.new(:lines) do
      def warn(msg) = lines << msg
    end.new([])
    [logger, yield(logger)]
  end

  def test_async_adapter_with_multiple_workers_is_broken
    logger, verdict = capture_warns do |l|
      RefreshSync::Health.check_cable_topology!(adapter: "async", web_concurrency: "4", logger: l)
    end
    assert_equal :broken, verdict
    assert_match(/WILL be silently lost/, logger.lines.first)
  end

  def test_async_adapter_single_process_still_warns
    logger, verdict = capture_warns do |l|
      RefreshSync::Health.check_cable_topology!(adapter: "async", web_concurrency: nil, logger: l)
    end
    assert_equal :single_process_only, verdict
    assert_match(/per-process/, logger.lines.first)
  end

  def test_cross_process_adapters_pass_silently
    logger, verdict = capture_warns do |l|
      RefreshSync::Health.check_cable_topology!(adapter: "solid_cable", web_concurrency: "4", logger: l)
    end
    assert_equal :ok, verdict
    assert_empty logger.lines
  end
end
