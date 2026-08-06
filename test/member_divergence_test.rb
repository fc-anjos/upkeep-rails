require_relative "test_helper"

# Per-member divergence: the flag-flip fix. A write matching a member's
# read set but not the promoted scrub render's read set changed something
# only that member depends on — that member is ejected to personal Tier P
# delivery while the surface stays shared for everyone else, and is
# re-admitted when their render matches the shared baseline again.
class MemberDivergenceTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def promote_vip
    @a = session_for(@alice)
    @c = session_for(@carol)
    @a.get "/vip_page"
    @stream_a = @a.response.headers["X-RefreshSync-Stream"]
    @c.get "/vip_page"
    @stream_c = @c.response.headers["X-RefreshSync-Stream"]
    assert_equal :shared, surface("vip_cards").status
  end

  def events(name)
    @events ||= Hash.new { |h, k| h[k] = [] }
    @subscribed ||= %w[member_diverged member_readmitted].each do |event|
      ActiveSupport::Notifications.subscribe("#{event}.refresh_sync") do |*args|
        @events[event] << ActiveSupport::Notifications::Event.new(*args).payload
      end
    end
    @events[name]
  end

  def teardown
    %w[member_diverged member_readmitted].each do |event|
      ActiveSupport::Notifications.unsubscribe("#{event}.refresh_sync")
    end
  end

  # Row-level flag flip: the member is ejected and personally refreshed;
  # the other viewer keeps shared delivery; the surface never demotes.
  def test_flag_flip_ejects_member_and_keeps_surface_shared
    events("member_diverged")
    promote_vip

    @carol.update!(beta: true)
    assert_refreshes(@stream_c, 1)
    assert_equal 0, broadcasts(@stream_a).size, "alice's delivery is untouched"
    assert surface("vip_cards").member_diverged?(@carol.id)
    refute surface("vip_cards").member_diverged?(@alice.id),
      "a row-level write attributes the divergence to exactly one member"
    assert_equal :shared, surface("vip_cards").status
    assert_equal [{ viewer: @carol.id.to_s, reason: :delta_row_write }],
      events("member_diverged").map { |p| p.slice(:viewer, :reason) }

    Card.create!(board: @board1, title: "After flip", status: "open")
    drain_debounce
    assert_equal 1, RefreshSync.stats[:surface_broadcasts],
      "the shared broadcast still goes out for everyone else"
    assert_equal 0, broadcasts(@stream_a).size, "alice is served by the broadcast alone"
    assert_operator broadcasts(@stream_c).size, :>=, 2,
      "the ejected member rides personal refresh instead"

    all_broadcast_payloads.each { |p| refute_match(/VIP LANE/, p) }
    assert_no_sentinel_broadcast
  end

  # The ejected member's next render carries their personal content, does
  # not poison the evidence pool, and does not demote the surface. Their
  # new page subscribes to its cohort stream only — not the surface stream.
  def test_divergent_rerender_stays_personal_without_demoting
    promote_vip
    @carol.update!(beta: true)
    drain_debounce
    Card.create!(board: @board1, title: "After flip", status: "open")
    drain_debounce

    @c.get "/vip_page"
    assert_includes @c.response.body, "VIP LANE", "her own render is correct for her"
    assert_equal :shared, surface("vip_cards").status, "her divergence is contained"
    assert surface("vip_cards").member_diverged?(@carol.id)
    assert_equal 1, @c.response.body.scan("<turbo-cable-stream-source ").size,
      "ejected member's page subscribes to its cohort stream only"

    @a.get "/vip_page"
    assert_equal 2, @a.response.body.scan("<turbo-cable-stream-source ").size,
      "a shared member's page subscribes to cohort + surface streams"

    # Covered writes now split: broadcast for the surface, refresh for her —
    # once at write time, plus the post-broadcast converge chase.
    new_stream_c = @c.response.headers["X-RefreshSync-Stream"]
    Card.create!(board: @board1, title: "While diverged", status: "open")
    drain_debounce
    drain_debounce
    assert_includes 1..2, broadcasts(new_stream_c).size,
      "the ejected member rides personal refresh"
    assert_equal 2, RefreshSync.stats[:surface_broadcasts]
    assert_no_sentinel_broadcast
  end

  # Flip the flag back: her next render matches the shared baseline and she
  # is re-admitted to shared delivery — no refreshes for her afterwards.
  def test_flag_revert_readmits_member
    events("member_readmitted")
    promote_vip
    @carol.update!(beta: true)
    drain_debounce
    Card.create!(board: @board1, title: "Baseline write", status: "open")
    drain_debounce

    @carol.update!(beta: false)
    drain_debounce
    @c.get "/vip_page"
    refute surface("vip_cards").member_diverged?(@carol.id),
      "digest matches the shared baseline again: re-admitted"
    assert_equal :shared, surface("vip_cards").status
    assert_equal [@carol.id.to_s], events("member_readmitted").map { |p| p[:viewer] }
    assert_equal 2, @c.response.body.scan("<turbo-cable-stream-source ").size,
      "re-admitted member's page subscribes to the surface stream again"

    new_stream_c = @c.response.headers["X-RefreshSync-Stream"]
    before = RefreshSync.stats[:surface_broadcasts]
    Card.create!(board: @board1, title: "After re-admission", status: "open")
    drain_debounce
    assert_equal before + 1, RefreshSync.stats[:surface_broadcasts]
    assert_no_refresh(new_stream_c)
    assert_no_sentinel_broadcast
  end

  # update_all skips callbacks and carries no row identity, so a bulk write
  # to a delta table ejects EVERY member whose read set matches — identity
  # fails closed, blunt but never wrong. Members whose next render matches
  # the baseline are immediately re-admitted.
  def test_update_all_flag_flip_ejects_and_matching_members_readmit
    promote_vip

    User.where(id: @carol.id).update_all(beta: true)
    assert_refreshes(@stream_c, 1)
    assert surface("vip_cards").member_diverged?(@carol.id)
    assert surface("vip_cards").member_diverged?(@alice.id),
      "table-level bulk cannot attribute rows: all matching members eject"
    assert_equal :shared, surface("vip_cards").status

    Card.create!(board: @board1, title: "Bulk window write", status: "open")
    drain_debounce
    assert_equal 1, RefreshSync.stats[:surface_broadcasts]
    all_broadcast_payloads.each { |p| refute_match(/VIP LANE/, p) }

    @a.get "/vip_page" # alice never actually diverged: her render matches
    refute surface("vip_cards").member_diverged?(@alice.id)
    @c.get "/vip_page" # carol genuinely diverged: she stays personal
    assert surface("vip_cards").member_diverged?(@carol.id)
    assert_equal :shared, surface("vip_cards").status
    assert_no_sentinel_broadcast
  end
end
