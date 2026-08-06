require_relative "test_helper"

# Per-iteration node identity: loop-body nodes are traced (and DOM-stamped)
# as address@table:id, derived at render time from the AST node path plus
# the loaded record identity already captured in the read set. A one-row
# change then travels as a one-row replace/remove instead of a whole-list
# replace. Identity fails closed: any evidence the ordinal<->row
# correspondence is unsound collapses back to the whole-region replace.
class RowIdentityTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def setup
    super
    Item.unscoped.delete_all
    @items = (1..5).map { |i| Item.create!(title: "Task #{i}", position: i) }
  end

  def surface_stream = surface("pulse_items").stream

  def decoded_broadcasts(stream)
    broadcasts(stream).map { |p| ActiveSupport::JSON.decode(p) }
  end

  def wait_for_broadcast(stream)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while broadcasts(stream).empty? &&
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    drain_debounce
  end

  # Promote pulse_items via role-diverse viewers. The cohorts' region
  # baselines are seeded from their own capture-time renders (no priming
  # write needed): the very first broadcast already diffs per cohort.
  def promote_and_baseline
    @alice_sess = session_for(@alice)
    @carol_sess = session_for(@carol)
    @alice_sess.get "/pulse/board"
    @carol_sess.get "/pulse/board"
    @served_body = @carol_sess.response.body
    assert_equal :region_shared, surface("pulse_items").status, "precondition: promoted"
  end

  def test_served_page_carries_per_row_instance_stamps
    promote_and_baseline
    @items.each do |item|
      assert_includes @served_body, "@items:#{item.id}",
        "each rendered row must carry its own instance stamp"
    end
  end

  def test_single_row_update_replaces_only_that_row
    promote_and_baseline
    item = @items.first
    item.update!(title: "Task 1 (row edit)")
    wait_for_broadcast(surface_stream)

    tags = decoded_broadcasts(surface_stream)
    replaces = tags.select { |t| t.include?(%(action="replace")) }
    removes = tags.select { |t| t.include?(%(action="remove")) }
    assert_equal 1, replaces.size, "exactly one row replace: #{tags.inspect}"
    assert_equal 0, removes.size
    tag = replaces.first
    assert_includes tag, "@items:#{item.id}", "the replace must target the row's instance address"
    assert_includes tag, "Task 1 (row edit)"
    refute_includes tag, "Task 2", "a row replace must not carry the rest of the list"
    assert_equal 1, Upkeep.stats[:region_row_replaces]
    assert_no_sentinel_broadcast
  end

  def test_single_row_removal_removes_only_that_row
    promote_and_baseline
    item = @items[1]
    item.destroy!
    wait_for_broadcast(surface_stream)

    tags = decoded_broadcasts(surface_stream)
    removes = tags.select { |t| t.include?(%(action="remove")) }
    replaces = tags.select { |t| t.include?(%(action="replace")) }
    assert_equal 1, removes.size, "exactly one row remove: #{tags.inspect}"
    assert_includes removes.first, "@items:#{item.id}"
    assert_equal 0, replaces.size, "no other row and no whole region may be replaced"
    assert_equal 1, Upkeep.stats[:region_row_removes]
    assert_no_sentinel_broadcast
  end

  # Insertion falls back to a whole-list-region replace BY DESIGN: digest
  # evidence proves which rows exist, not where a new row sits relative to
  # the viewer's DOM, and a wrong position is corruption while a whole-list
  # replace is merely coarser. Documented in README.
  def test_row_insertion_falls_back_to_whole_region_replace
    promote_and_baseline
    Item.create!(title: "Task 0", position: 0)
    wait_for_broadcast(surface_stream)

    tags = decoded_broadcasts(surface_stream)
    replaces = tags.select { |t| t.include?(%(action="replace")) }
    removes = tags.select { |t| t.include?(%(action="remove")) }
    assert_equal 1, replaces.size, "one whole-region replace: #{tags.inspect}"
    assert_equal 0, removes.size, "the displaced row rides inside the region replace"
    tag = replaces.first
    assert_includes tag, "Task 0"
    assert_includes tag, "Task 1", "the whole list region is replaced"
    region = surface("pulse_items").region_addresses.find { |a| tag.include?("targets=\"[data-rs-node=&#39;#{a}&#39;]\"") }
    assert region, "the replace must target a stable (non-instance) region address"
    refute_includes region, "@"
    assert_equal 0, Upkeep.stats[:region_row_replaces]
    assert_no_sentinel_broadcast
  end

  # Fail closed: a loop that skips a row breaks the ordinal<->row
  # correspondence; identity voids itself and one-row changes arrive as
  # whole-region replaces instead of (wrongly targeted) row replaces.
  def test_unsound_iteration_mapping_voids_row_targeting
    a_sess = session_for(@alice)
    c_sess = session_for(@carol)
    a_sess.get "/pulse/skip_board"
    c_sess.get "/pulse/skip_board"
    s = surface("pulse_skiplist")
    assert s.tier_s?, "skip list still promotes (unsoundness is not divergence), got #{s.status}/#{s.pin_reason}"
    skip_stream = s.stream

    @items[3].update!(title: "Task 4 (skiplist baseline)")
    wait_for_broadcast(skip_stream)
    ActionCable.server.pubsub.clear

    @items.first.update!(title: "Task 1 (skiplist edit)")
    wait_for_broadcast(skip_stream)
    tags = decoded_broadcasts(skip_stream)
    replaces = tags.select { |t| t.include?(%(action="replace")) }
    assert_operator replaces.size, :>=, 1, "the change still goes out: #{tags.inspect}"
    assert_equal 0, Upkeep.stats[:region_row_replaces],
      "row targeting must be voided for an unsound loop"
    assert_equal 0, Upkeep.stats[:region_row_removes]
    assert replaces.any? { |t| t.include?("Task 1 (skiplist edit)") }
    replaces.each do |t|
      target = t[/targets="\[data-rs-node=&#39;([^&]*)&#39;\]"/, 1]
      assert target, "replace must carry a node target: #{t[0, 120]}"
      refute_includes target, "@", "no instance-targeted replace, got #{target}"
    end
    assert_no_sentinel_broadcast
  end
end
