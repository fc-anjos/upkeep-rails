require_relative "test_helper"

# Liveness legibility: every *.upkeep event is classified by stakes in ONE
# exhaustive map. LIVENESS LOST raises in development/test (production:
# warn + degrade, unchanged); LIVENESS COARSENED never raises; an event the
# map does not know raises unconditionally in dev/test — the enforcement
# that adding an event without classifying it is impossible.
class LegibilityClassificationTest < ActiveSupport::TestCase
  include ProofHelpers

  EMITTED_EVENTS = begin
    lib = File.join(PROTO_ROOT, "lib")
    sources = Dir[File.join(lib, "**", "*.rb")].map { |f| File.read(f) }
    explicit = sources.flat_map { |s| s.scan(/"([a-z_]+)\.upkeep"/) }.flatten
    # Surface#instrument interpolates: instrument("event", ...) sites,
    # including the ternary form instrument(cond ? "a" : "b", ...).
    surface = File.read(File.join(lib, "upkeep", "surfaces.rb"))
    interpolated = surface
                   .scan(/\binstrument\(\s*(?:[a-z_]+\s*\?\s*)?"([a-z_]+)"(?:\s*:\s*"([a-z_]+)")?/m)
                   .flatten.compact
    (explicit + interpolated).uniq.sort
  end

  def test_every_emitted_event_is_classified
    unclassified = EMITTED_EVENTS.reject { |e| Upkeep::Legibility::TIERS.key?(e) }
    assert_empty unclassified,
      "every emitted *.upkeep event must appear in Legibility::TIERS"
  end

  def test_every_classification_names_an_emitted_event
    stale = Upkeep::Legibility::TIERS.keys - EMITTED_EVENTS
    assert_empty stale, "TIERS must not classify events nothing emits"
  end

  def test_tiers_are_lost_coarsened_or_info
    Upkeep::Legibility::TIERS.each do |event, tier|
      resolved = tier.respond_to?(:call) ? tier.call({}) : tier
      assert_includes %i[lost coarsened info], resolved,
        "#{event} resolves to an unknown tier"
    end
  end

  def test_payload_dependent_classifications
    assert_equal :lost,
      Upkeep::Legibility.tier_for("capture_incomplete", mode: :unattributable)
    assert_equal :coarsened,
      Upkeep::Legibility.tier_for("capture_incomplete", mode: :degraded_table_level)
    assert_equal :lost, Upkeep::Legibility.tier_for("cable_topology", verdict: :broken)
    assert_equal :info,
      Upkeep::Legibility.tier_for("cable_topology", verdict: :single_process_only)
  end

  def test_unclassified_event_raises_in_test_env
    error = assert_raises(Upkeep::UnclassifiedEvent) do
      ActiveSupport::Notifications.instrument("brand_new_thing.upkeep", a: 1)
    end
    assert_match(/brand_new_thing/, error.message)
    assert_match(/Legibility::TIERS/, error.message)
  end

  def test_unclassified_event_raises_even_with_no_raise_opt_out
    no_raise do
      assert_raises(Upkeep::UnclassifiedEvent) do
        ActiveSupport::Notifications.instrument("brand_new_thing.upkeep")
      end
    end
  end

  def test_lost_event_raises_actionably_in_test_env
    error = assert_raises(Upkeep::LivenessLost) do
      ActiveSupport::Notifications.instrument(
        "capture_refused.upkeep",
        reason: :unattributable_read, detail: "unnamed query", path: "/boards/1"
      )
    end
    assert_match(/liveness lost/i, error.message)
    assert_match(%r{/boards/1}, error.message)
    assert_match(/unnamed query/, error.message)
    assert_match(/fix:/i, error.message)
    assert_match(/UPKEEP_NO_RAISE/, error.message)
  end

  def test_lost_event_message_points_at_app_code
    error = assert_raises(Upkeep::LivenessLost) do
      ActiveSupport::Notifications.instrument(
        "unattributed_write.upkeep", sql_head: "REPLACE INTO cards ..."
      )
    end
    assert_match(%r{at: .*legibility_test\.rb:\d+}, error.message,
      "the error must carry the nearest app-code frame, not gem internals")
  end

  def test_coarsened_and_info_events_never_raise
    ActiveSupport::Notifications.instrument(
      "capture_incomplete.upkeep", mode: :degraded_table_level, table: "cards"
    )
    ActiveSupport::Notifications.instrument("refresh_netted.upkeep", stream: "s")
    assert true, "coarsened and info events must pass through silently"
  end

  def test_no_raise_env_var_downgrades_lost_to_warn
    no_raise do
      refute Upkeep::Legibility.raise_lost?
      ActiveSupport::Notifications.instrument(
        "capture_refused.upkeep", reason: :unattributable_read, path: "/x"
      )
    end
  end

  def test_production_env_never_raises
    Upkeep::Legibility.env = "production"
    refute Upkeep::Legibility.enforcing?
    ActiveSupport::Notifications.instrument(
      "capture_refused.upkeep", reason: :unattributable_read, path: "/x"
    )
    ActiveSupport::Notifications.instrument("brand_new_thing.upkeep")
  ensure
    Upkeep::Legibility.env = nil
  end

  def test_development_env_raises
    Upkeep::Legibility.env = "development"
    assert_raises(Upkeep::LivenessLost) do
      ActiveSupport::Notifications.instrument(
        "capture_refused.upkeep", reason: :unattributable_read, path: "/x"
      )
    end
  ensure
    Upkeep::Legibility.env = nil
  end
end

# The raise fires where liveness is actually lost, with the app frame in
# reach: end-to-end through the real capture and write paths.
class LegibilityIntegrationTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_unattributable_read_raises_during_the_request
    error = assert_raises(Upkeep::LivenessLost) { get "/doors/raw_anonymous" }
    assert_match(/unattributable/, error.message)
    assert_match(/no cohort/i, error.message)
  end

  def test_ignored_table_write_on_a_watched_table_raises
    sess = session_for(@alice)
    sess.get "/audit_log"

    error = assert_raises(Upkeep::LivenessLost) do
      AuditRecord.create!(action: "board.rename")
    end
    assert_match(/audits/, error.message)
    assert_match(/ignore/, error.message)
    assert_equal 1, AuditRecord.where(action: "board.rename").count,
      "the raise happens after commit: the write itself is untouched"
  end

  def test_missing_body_tag_raises_when_injection_is_on
    with_auto_subscribe do
      error = assert_raises(Upkeep::LivenessLost) { get "/boards/#{@board1.id}" }
      assert_match(/<\/body>/, error.message)
      assert_match(/auto_subscribe/, error.message)
    end
  end

  def test_broken_cable_topology_raises
    error = assert_raises(Upkeep::LivenessLost) do
      Upkeep::Health.check_cable_topology!(
        adapter: "async", web_concurrency: "4", logger: Logger.new(IO::NULL)
      )
    end
    assert_match(/async/, error.message)
  end
end
