require_relative "test_helper"

# The Rails-leverage batch: commit deferral / rollback discard, zero-row
# skip, exact bulk row identity (RETURNING probe + insert_all result ids),
# the emergency kill switch, and column-refined member divergence.
class PlatformSignalsTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_rolled_back_bulk_write_refreshes_nobody
    stream = visit_board(@board1)
    Card.transaction do
      Card.where(id: @card1.id).update_all(title: "Rolled back")
      raise ActiveRecord::Rollback
    end
    assert_no_refresh(stream)
  end

  def test_committed_transactional_bulk_write_refreshes_after_commit
    stream = visit_board(@board1)
    Card.transaction do
      Card.where(id: @card1.id).update_all(title: "Committed")
      # Inside the transaction nothing has been scheduled yet.
      assert_equal 0, Upkeep.debouncer.pending_count
    end
    assert_refreshes(stream, 1)
  end

  def test_bulk_write_matching_zero_rows_reports_nothing
    stream = visit_board(@board1)
    assert_equal 0, Card.where(title: "NO SUCH").update_all(status: "closed")
    assert_no_refresh(stream)
  end

  def test_returning_gives_bulk_writes_exact_row_identity
    stream1 = visit_board(@board1)
    stream2 = open_session.then { |s| s.get "/boards/#{@board2.id}"; s.response.headers["X-Upkeep-Stream"] }
    assert stream2

    # A bulk write to board2's row only: with table-level identity both
    # cohorts would refresh (boards deps are pk predicates); with RETURNING
    # ids only board2's cohort does.
    Board.where(id: @board2.id).update_all(name: "Renamed Two")
    assert_refreshes(stream2, 1)
    assert_equal 0, broadcasts(stream1).size, "board1 cohort must not refresh for board2's row"
  end

  def test_returning_probe_failure_degrades_to_table_level
    Upkeep::RowIdentity.reset!
    Upkeep::RowIdentity.singleton_class.class_eval do
      alias_method :_orig_probe, :probe
      define_method(:probe) { |_conn| false }
    end
    stream1 = visit_board(@board1)
    events = []
    sub = ActiveSupport::Notifications.subscribe("row_identity_unavailable.upkeep") { |e| events << e.payload }
    Board.where(id: @board2.id).update_all(name: "Blunt")
    # Table-level fallback: board1's cohort refreshes too (over-delivery,
    # never staleness), and the degrade warned loudly.
    assert_refreshes(stream1, 1)
    assert events.any?, "probe failure must instrument row_identity_unavailable"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
    Upkeep::RowIdentity.singleton_class.class_eval do
      define_method(:probe) { |conn| _orig_probe(conn) }
    end
    Upkeep::RowIdentity.reset!
  end

  def test_insert_all_ids_ride_the_returned_result
    stream = visit_board(@board1)
    Board.insert_all([ { name: "Fresh A" }, { name: "Fresh B" } ])
    # The cohort's boards dependency is a pure pk predicate (Board.find):
    # brand-new ids cannot match it, so no refresh — and no degrade warning
    # because the ids were really present in Rails' returned result.
    assert_no_refresh(stream)
    assert_equal 0, Upkeep.stats[:insert_all_without_ids]
  end

  def test_kill_switch_forces_refresh_only
    ENV["UPKEEP_DISABLE_REGION_BROADCAST"] = "1"
    alice = session_for(@alice)
    carol = session_for(@carol)
    alice.get "/shared_board"
    carol.get "/shared_board"
    s = surface("open_cards")
    stream = carol.response.headers["X-Upkeep-Stream"]
    assert s.tier_s?, "promotion evidence still accumulates under the kill switch"
    Card.create!(board: @board1, title: "Killed", status: "open")
    assert_refreshes(stream, 1)
    assert_equal 0, broadcasts(s.stream).size, "no shared payload under the kill switch"
  ensure
    ENV.delete("UPKEEP_DISABLE_REGION_BROADCAST")
  end

  def test_column_intersection_resolves_shared_and_personal_rows
    surface = Upkeep::Surface.new(name: "col", deploy_key: "deploy-1")
    shared = Upkeep::ReadSet.new
    shared.record_id("users", 7)
    shared.record_column("users", "name")
    surface.instance_variable_set(:@status, :shared)
    surface.instance_variable_set(:@shared_read_set, shared)

    admin_flip = Upkeep::Change.new(
      table: "users", id: 7, kind: :update,
      new_attrs: { "id" => 7, "role" => "admin" }, columns: ["role"]
    )
    rename = Upkeep::Change.new(
      table: "users", id: 7, kind: :update,
      new_attrs: { "id" => 7, "name" => "New" }, columns: ["name"]
    )
    unknown_columns = Upkeep::Change.new(table: "users", id: 7, kind: :update)

    assert surface.personal_change?(admin_flip),
      "a write to columns the scrub render never read is personal"
    refute surface.personal_change?(rename),
      "a write to columns the scrub render read is shared invalidation"
    refute surface.personal_change?(unknown_columns),
      "missing column info fails open to row-level behavior"
  end

  def test_capture_records_column_reads
    visit_board(@board1)
    columns = Upkeep::Capture.last_recording.read_set.columns("cards")
    assert columns, "rendered attribute reads produce column evidence"
    assert_includes columns, "title"
  end
end

# Pagy-style Array locals: templates receive plain Arrays of records, not
# relations. They are now rebuildable (ordered id fetch), so such surfaces
# can promote and their scrub renders see CURRENT data.
class ArrayLocalsTest < ActiveSupport::TestCase
  include ProofHelpers

  def descriptor(cards)
    Upkeep::Descriptor.new(name: "page", partial: "surfaces/cards", locals: { cards: cards })
  end

  def test_record_arrays_are_refreshable_and_round_trip
    cards = Card.where(status: "open").order(:id).to_a
    d = descriptor(cards)
    assert d.refreshable?, "a homogeneous persisted-record array is rebuildable"
    assert_equal ["cards"], d.tables

    revived = Upkeep::Descriptor.from_h(JSON.parse(JSON.generate(d.to_h)))
    assert_equal cards.map(&:id), revived.locals[:cards].map(&:id)
  end

  def test_scrub_render_refetches_array_records
    cards = Card.where(id: @card1.id).to_a
    d = descriptor(cards)
    @card1.update!(title: "Freshened")
    result = Upkeep::SharedRender.call(d)
    assert_includes result.html, "Freshened",
      "scrub render must see current data, not captured record objects"
  end

  def test_mixed_or_unpersisted_arrays_stay_unrefreshable
    refute descriptor([Card.new(title: "ghost")]).refreshable?
    refute descriptor([@card1, @board1]).refreshable?
  end
end

# F3: automatic surface detection — top-level partials rendered during a
# capture become candidates with no declaration; the evidence machinery
# decides everything else.
class AutoSurfacesTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def render_page(locals)
    recording = Upkeep::Recording.start
    html = ScrubbedController.render(partial: "surfaces/cards", locals: locals)
    [recording, html]
  ensure
    Upkeep::Recording.finish
  end

  def test_top_level_partial_renders_become_candidates
    recording, = render_page(cards: Card.where(status: "open"))
    candidate = recording.surfaces.find { |o| o.descriptor.name == "auto:surfaces/_cards" }
    assert candidate, "an undeclared partial render must produce a surface candidate"
    assert_equal ["cards"], candidate.descriptor.tables
    assert candidate.digest
  end

  def test_unrebuildable_locals_never_become_candidates
    recording, = render_page(cards: [Card.new(title: "ghost")])
    assert_empty recording.surfaces, "nothing to scrub-render later: no candidate"
  end

  def test_auto_candidates_promote_through_the_normal_evidence_bar
    Upkeep.registry = Upkeep::SurfaceRegistry.new
    recording, = render_page(cards: Card.where(status: "open"))
    observation = recording.surfaces.first
    surface = Upkeep.registry.upsert(observation.descriptor.name)
    surface.observe(observation, viewer: Upkeep::Viewer.new(id: 1, role: "user"),
                    cohort_stream: "s1", ambient: Set.new, identity_bound: false)
    surface.observe(observation, viewer: Upkeep::Viewer.new(id: 2, role: "admin"),
                    cohort_stream: "s2", ambient: Set.new, identity_bound: false)
    assert surface.tier_s?, "role-diverse identical evidence promotes an auto candidate"
  end

  def test_declared_shared_surfaces_suppress_double_observation
    a = session_for(@alice)
    a.get "/shared_board"
    names = Upkeep::Capture.last_recording.surfaces.map { |o| o.descriptor.name }
    assert_includes names, "open_cards"
    refute names.any? { |n| n.start_with?("auto:") && n.include?("_cards") },
      "the declared surface's own partial must not double-register as auto"
  end
end
