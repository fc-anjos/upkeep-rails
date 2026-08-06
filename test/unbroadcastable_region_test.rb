require_relative "test_helper"

# Unbroadcastable-region detection: byte-shared content with no enclosing
# stamped element (here, a cache block directly in flow) cannot be targeted
# by a region broadcast. This must be DETECTED at evidence time and reported
# through instrumentation (region_unbroadcastable, naming template and
# region) so operators know why Tier S skips it — never by requiring or
# suggesting template changes: refresh covers it as a correctness matter.
class UnbroadcastableRegionTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def setup
    super
    Item.unscoped.delete_all
    @items = (1..5).map { |i| Item.create!(title: "Task #{i}", position: i) }
  end

  def test_bare_cache_block_is_reported_and_covered_by_refresh
    events = []
    sub = ActiveSupport::Notifications.subscribe("region_unbroadcastable.upkeep") do |*_a, payload|
      events << payload
    end

    a_sess = session_for(@alice)
    c_sess = session_for(@carol)
    a_sess.get "/pulse/bare_board"
    a_stream = a_sess.response.headers["X-Upkeep-Stream"]
    c_sess.get "/pulse/bare_board"

    s = surface("pulse_bare")
    assert_equal :region_shared, s.status,
      "the page still promotes (detection is a signal, not a pin): #{s.status}/#{s.pin_reason}"
    assert s.region_addresses.any?, "the stamped list is still a region"

    event = events.find { |p| p[:name] == "pulse_bare" }
    assert event, "region_unbroadcastable must fire at evidence time: #{events.inspect}"
    assert_equal :no_enclosing_stamped_element, event[:reason]
    assert event[:regions].any?, "the event names the unbroadcastable regions"
    assert event[:regions].all? { |r| r[:address].start_with?("t:") }
    assert event[:regions].any? { |r| r[:template] == "pulse/_bare.html.erb" },
      "the event names the template: #{event[:regions].inspect}"
    assert event[:regions].none? { |r| s.region_addresses.include?(r[:address]) },
      "reported regions are exactly the ones Tier S cannot target"
    assert_operator Upkeep.stats[:regions_unbroadcastable], :>=, 1

    # Correctness rides on refresh: a write matching the cache block's
    # dependencies (outside every broadcastable region) refreshes viewers.
    @items.first.update!(title: "Task 1 (bare edit)")
    assert_refreshes(a_stream, 1)
    assert_no_sentinel_broadcast
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
