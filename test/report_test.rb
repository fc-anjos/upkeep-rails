require_relative "test_helper"

# rails upkeep:report — the static liveness map from the persisted store:
# every known page (cohorts grouped by captured path), each surface's tier
# and pin reason, and recorded degradations with reasons. Plain text for a
# terminal or CI; UPKEEP_REPORT_JSON=1 emits the same map as JSON.
class ReportTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def register_pages
    sim = sim_process
    in_process(sim) do
      get "/opaque_cards"
      assert_response :success
      session_for(@alice).get "/dashboard"
      a = session_for(@alice)
      c = session_for(@carol)
      a.get "/shared_board"
      c.get "/shared_board"
    end
  end

  def test_report_maps_pages_tiers_surfaces_and_degradations
    register_pages
    text = Upkeep::Report.build.to_text

    assert_match(/upkeep liveness report/, text)
    assert_match(/deploy deploy-1/, text)

    # Pages, by captured path, with their tables.
    assert_match(/GET \/opaque_cards — 1 cohort/, text)
    assert_match(/tables: cards/, text)
    assert_match(/GET \/shared_board — 2 cohorts/, text)

    # Recorded degradations with reasons.
    assert_match(/degraded: cards → table-level \(unanalyzable_grouping\)/, text)

    # Surfaces with their tier.
    assert_match(/open_cards\s+Tier S \(shared\)/, text)
    assert_match(/my_cards\s+Tier P \(pinned: identity_predicate\)/, text)
  end

  def test_report_shows_activation_state
    sim = sim_process
    stream = nil
    in_process(sim) do
      get "/cards"
      stream = response.headers["X-Upkeep-Stream"]
      sim.store.mark_subscribed(stream)
    end

    text = Upkeep::Report.build.to_text
    assert_match(/GET \/cards — 1 cohort \(1 activated\)/, text)
  end

  def test_json_output_is_the_same_map
    register_pages
    json = Upkeep::Report.build.as_json

    assert_equal "deploy-1", json[:deploy_key]
    page = json[:pages].find { |p| p[:path] == "/opaque_cards" }
    assert page, "every captured path appears: #{json[:pages].inspect}"
    assert_equal ["cards"], page[:tables]
    assert_equal({ "cards" => ["unanalyzable_grouping"] }, page[:degradations])

    shared = json[:surfaces].find { |s| s[:name] == "open_cards" }
    assert_equal "S", shared[:tier]
    assert_equal "shared", shared[:status]
    pinned = json[:surfaces].find { |s| s[:name] == "my_cards" }
    assert_equal "P", pinned[:tier]
    assert_equal "identity_predicate", pinned[:pin_reason]
  end

  def test_empty_store_reports_no_pages
    text = Upkeep::Report.build.to_text
    assert_match(/no cohorts registered/, text)
  end

  def test_rake_task_is_defined
    require "rake"
    Rake::Task.clear
    load File.join(PROTO_ROOT, "lib", "upkeep", "tasks", "report.rake")
    assert Rake::Task.task_defined?("upkeep:report")
  end
end
