require_relative "test_helper"

# The delivery-ordering invariant (README) as a MECHANISM instead of a
# convention: every capture response carries X-Upkeep-Generation
# (per-surface write generation at render time) and every Tier S broadcast
# tag carries data-upkeep-gen. The client rule — apply a full-page morph only if
# its generation is >= the newest applied region update, otherwise discard
# and re-fetch — is what prevents a stale in-flight GET from silently
# rolling back an applied region update. The client is simulated here, the
# same way origin_test simulates Turbo's request-id discard.
class DeliveryOrderingTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  SURFACE = "pulse_items"

  # The documented client contract, minimally.
  class SimViewer
    attr_reader :dom, :generation

    def initialize(body, generation)
      @dom = body
      @generation = generation
    end

    def apply_region(html, gen)
      return :discarded if gen < @generation
      @generation = gen if gen > @generation
      @dom = html # stands in for replacing the region subtree
      :applied
    end

    def apply_morph(body, gen)
      return :suppressed_refetch if gen < @generation
      @generation = gen
      @dom = body
      :applied
    end
  end

  def setup
    super
    Item.unscoped.delete_all
    @items = (1..5).map { |i| Item.create!(title: "Task #{i}", position: i) }
  end

  def surface_stream = surface(SURFACE).stream

  def decoded(stream)
    broadcasts(stream).map { |p| ActiveSupport::JSON.decode(p) }
  end

  def wait_for(stream)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while broadcasts(stream).empty? &&
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    drain_debounce
  end

  def gen_from_header(response)
    pair = response.headers["X-Upkeep-Generation"].to_s.split(",")
                   .find { |p| p.start_with?("#{SURFACE}=") }
    pair && pair.split("=").last.to_i
  end

  def gen_from_tag(tag)
    tag[/data-upkeep-gen="(\d+)"/, 1]&.to_i
  end

  def subscribe
    @alice_sess = session_for(@alice)
    @carol_sess = session_for(@carol)
    @alice_sess.get "/pulse/board"
    @carol_sess.get "/pulse/board"
    assert_equal :region_shared, surface(SURFACE).status, "precondition: promoted"
  end

  def test_pages_and_broadcasts_carry_comparable_generation_stamps
    subscribe
    page_gen = gen_from_header(@carol_sess.response)
    assert page_gen, "capture responses must carry the surface generation"

    @items.first.update!(title: "Task 1 (stamped)")
    wait_for(surface_stream)
    tags = decoded(surface_stream)
    assert tags.any?, "the write must produce a broadcast"
    tags.each do |tag|
      tag_gen = gen_from_tag(tag)
      assert tag_gen, "every Tier S tag carries data-upkeep-gen: #{tag[0, 120]}"
      assert_operator tag_gen, :>, page_gen,
        "the update's generation must supersede the pre-write page"
    end
  end

  def test_stale_inflight_morph_cannot_clobber_a_newer_region_update
    subscribe
    viewer = SimViewer.new(@alice_sess.response.body, gen_from_header(@alice_sess.response))

    # An in-flight GET: rendered NOW (pre-write), applied at the client
    # LATER — the interleaving the convention used to survive by luck.
    @alice_sess.get "/pulse/board"
    stale_body = @alice_sess.response.body
    stale_gen = gen_from_header(@alice_sess.response)

    @items.first.update!(title: "Task 1 (post-stale)")
    wait_for(surface_stream)
    replace = decoded(surface_stream).find { |t| t.include?("Task 1 (post-stale)") }
    assert replace, "the covered write arrives as a region update"

    assert_equal :applied, viewer.apply_region(replace, gen_from_tag(replace))
    assert_includes viewer.dom, "Task 1 (post-stale)"

    # The luck-hole is real: the stale body predates the write, so a naive
    # client applying it would silently lose the update with nothing
    # pending to fix it.
    refute_includes stale_body, "Task 1 (post-stale)"

    # The mechanism: the stale morph's generation is older than the applied
    # region update — the client suppresses it and re-fetches.
    assert_equal :suppressed_refetch, viewer.apply_morph(stale_body, stale_gen)
    assert_includes viewer.dom, "Task 1 (post-stale)", "the applied update survives"

    @alice_sess.get "/pulse/board"
    fresh_gen = gen_from_header(@alice_sess.response)
    assert_operator fresh_gen, :>=, viewer.generation
    assert_equal :applied, viewer.apply_morph(@alice_sess.response.body, fresh_gen)
    assert_includes viewer.dom, "Task 1 (post-stale)", "the re-fetch converges"
    assert_no_sentinel_broadcast
  end
end
