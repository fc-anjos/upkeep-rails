# frozen_string_literal: true

require "test_helper"

class HerbManifestDiffTest < Minitest::Test
  def test_noops_identical_sources
    plan = diff_plan("<main><h1>Launch</h1></main>", "<main><h1>Launch</h1></main>")

    assert_equal "noop", plan.action
    assert_equal "identical_source", plan.reason
    refute plan.topology_changed
    assert_empty plan.operation_types
    assert plan.gate_passed?
  end

  def test_refreshes_manifest_for_content_only_stable_topology
    old_source = '<main><h1 class="old">Launch</h1><%= render partial: "cards/card", collection: cards, as: :card %></main>'
    new_source = '<main><h1 class="new">Launch v2</h1><%= render partial: "cards/card", collection: cards, as: :card %></main>'

    plan = diff_plan(old_source, new_source)

    assert_equal "refresh_manifest", plan.action
    assert_equal "content_only_stable_topology", plan.reason
    refute plan.topology_changed
    assert_equal %w[attribute_value_changed text_changed], plan.operation_types.sort
    assert_equal plan.old_topology_signature, plan.new_topology_signature
    assert plan.gate_passed?
  end

  def test_rebuilds_manifest_when_render_expression_changes
    old_source = '<main><%= render partial: "cards/card", collection: cards, as: :card %></main>'
    new_source = '<main><%= render partial: "cards/card", collection: visible_cards(cards), as: :card %></main>'

    plan = diff_plan(old_source, new_source)

    assert_equal "rebuild_manifest", plan.action
    assert_equal "manifest_topology_changed", plan.reason
    assert plan.topology_changed
    assert_includes plan.operation_types, "erb_content_changed"
    refute_equal plan.old_topology_signature, plan.new_topology_signature
  end

  def test_rebuilds_manifest_when_root_shape_changes
    plan = diff_plan("<li>One</li>", "<li>One</li><li>Two</li>", path: "cards/_card")

    assert_equal "rebuild_manifest", plan.action
    assert_equal "manifest_topology_changed", plan.reason
    assert plan.topology_changed
    assert_includes plan.operation_types, "node_inserted"
    refute_equal plan.old_topology_signature, plan.new_topology_signature
  end

  def test_full_rebuild_when_manifest_parse_fails
    plan = diff_plan("<div></div>", "<div><span></div>")

    assert_equal "full_rebuild", plan.action
    assert_equal "manifest_parse_failure", plan.reason
    assert plan.topology_changed
    assert plan.gate_passed?
  end

  private

  def diff_plan(old_source, new_source, path: "boards/show")
    Upkeep::HerbSupport::ManifestDiff.plan(path: path, old_source: old_source, new_source: new_source)
  end
end
