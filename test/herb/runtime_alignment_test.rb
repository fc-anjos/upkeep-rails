# frozen_string_literal: true

require "test_helper"

class HerbRuntimeAlignmentTest < Minitest::Test
  def test_matches_runtime_frames_to_manifest_entries
    manifests = build_manifests
    page_manifest, fragment_manifest = manifests
    render_site_id = page_manifest.render_nodes.first.fetch(:site_id)
    graph = Upkeep::DAG::Graph.new
    graph.add_node("page:boards/show", kind: :frame, payload: manifest_payload(page_manifest).merge(kind: "page", template: "boards/show"))
    graph.add_node("site:#{render_site_id}", kind: :frame, payload: manifest_payload(page_manifest).merge(kind: "render_site", site_id: render_site_id))
    graph.add_node("fragment:cards/_card:cards:1", kind: :frame, payload: manifest_payload(fragment_manifest).merge(kind: "fragment", template: "cards/_card"))

    report = Upkeep::HerbSupport::RuntimeAlignment.new(manifests: manifests).report(
      graph: graph,
      selected_targets: [
        Upkeep::Targeting::Target.new("render_site", render_site_id, "test"),
        Upkeep::Targeting::Target.new("fragment", "fragment:cards/_card:cards:1", "test")
      ]
    )

    assert report.fetch(:summary).fetch(:gate_passed)
    assert_equal 3, report.fetch(:summary).fetch(:matched_frames)
    assert_equal 2, report.fetch(:summary).fetch(:matched_selected_targets)
    assert_empty report.fetch(:summary).fetch(:frame_deopt_reasons)
  end

  def test_reports_specific_deopt_reason_for_manifest_provenance_mismatch
    manifests = build_manifests
    page_manifest = manifests.first
    graph = Upkeep::DAG::Graph.new
    graph.add_node(
      "page:boards/show",
      kind: :frame,
      payload: manifest_payload(page_manifest).merge(kind: "page", template: "boards/show", manifest_fingerprint: "stale")
    )

    report = Upkeep::HerbSupport::RuntimeAlignment.new(manifests: manifests).report(graph: graph)

    assert report.fetch(:summary).fetch(:gate_passed)
    assert_equal({ "runtime_manifest_fingerprint_mismatch" => 1 }, report.fetch(:summary).fetch(:frame_deopt_reasons))
    assert_equal "runtime_manifest_fingerprint_mismatch", report.fetch(:frames).first.fetch(:deopt_reason)
  end

  def test_reports_specific_deopt_reason_for_unplanned_render_site
    graph = Upkeep::DAG::Graph.new
    graph.add_node("site:missing", kind: :frame, payload: { kind: "render_site", site_id: "missing" })

    report = Upkeep::HerbSupport::RuntimeAlignment.new(manifests: build_manifests).report(graph: graph)

    assert report.fetch(:summary).fetch(:gate_passed)
    assert_equal({ "render_site_missing_from_manifest" => 1 }, report.fetch(:summary).fetch(:frame_deopt_reasons))
    assert_equal "render_site_missing_from_manifest", report.fetch(:frames).first.fetch(:deopt_reason)
  end

  private

  def build_manifests
    [
      Upkeep::Templates::Template.new("boards/show", '<main><%= render partial: "cards/card", collection: cards, as: :card %></main>', :page),
      Upkeep::Templates::Template.new("cards/_card", "<li><%= card.title %></li>", :partial)
    ].then { |templates| Upkeep::HerbSupport::RuntimeAlignment.build_manifests(templates) }
  end

  def manifest_payload(manifest)
    {
      manifest_path: manifest.path,
      manifest_fingerprint: manifest.fingerprint
    }
  end
end
