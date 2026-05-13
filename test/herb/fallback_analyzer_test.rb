# frozen_string_literal: true

require "test_helper"

class HerbFallbackAnalyzerTest < Minitest::Test
  FakeDependency = Data.define(:cache_key, :source) do
    def matches_change?(change)
      change == cache_key
    end

    def to_h
      { source: source, key: cache_key }
    end
  end

  def test_explains_preloaded_plain_data
    graph = graph_with_page("boards/preloaded_plain")
    graph.add_dependency(Upkeep::Runtime::Recorder::REQUEST_NODE_ID, FakeDependency.new(:changed, :active_record_attribute))

    assert_equal "preloaded_plain_data", fallback_reason(graph, "page:boards/preloaded_plain", changes: [:changed])
  end

  def test_explains_helper_hidden_collection
    graph = graph_with_page("boards/helper_hidden")
    graph.add_node("fragment:cards/_card:cards:1", kind: :frame, payload: { kind: "fragment", template: "cards/_card" })
    graph.add_edge("page:boards/helper_hidden", "fragment:cards/_card:cards:1", reason: :contains)
    graph.add_dependency("page:boards/helper_hidden", FakeDependency.new(:changed, :active_record_collection))

    assert_equal "helper_hidden_collection", fallback_reason(graph, "page:boards/helper_hidden", changes: [:changed])
  end

  def test_explains_missing_render_site
    graph = graph_with_page("boards/inline")
    graph.add_dependency("page:boards/inline", FakeDependency.new(:changed, :active_record_attribute))

    assert_equal "no_herb_render_site", fallback_reason(graph, "page:boards/inline", changes: [:changed])
  end

  def test_manifest_mismatch_takes_precedence
    graph = graph_with_page("boards/inline")
    alignment_report = {
      summary: {
        frame_deopt_reasons: { "render_site_missing_from_manifest" => 1 },
        selected_target_deopt_reasons: {}
      }
    }

    analyzer = Upkeep::HerbSupport::FallbackAnalyzer.new(manifests: manifests, alignment_report: alignment_report)

    assert_equal "manifest_runtime_mismatch", analyzer.fallback_reason_for(
      graph: graph,
      target: Upkeep::Targeting::Target.new("page", "page:boards/inline", "test"),
      changes: []
    )
  end

  private

  def fallback_reason(graph, target_id, changes:)
    analyzer = Upkeep::HerbSupport::FallbackAnalyzer.new(
      manifests: manifests,
      alignment_report: { summary: { frame_deopt_reasons: {}, selected_target_deopt_reasons: {} } }
    )

    analyzer.fallback_reason_for(
      graph: graph,
      target: Upkeep::Targeting::Target.new("page", target_id, "test"),
      changes: changes
    )
  end

  def graph_with_page(template)
    Upkeep::DAG::Graph.new.tap do |graph|
      graph.add_node("page:#{template}", kind: :frame, payload: { kind: "page", template: template })
    end
  end

  def manifests
    [
      Upkeep::Templates::Template.new("boards/preloaded_plain", "<main><%= summary.title %></main>", :page),
      Upkeep::Templates::Template.new("boards/helper_hidden", "<main><%= helper_hidden_card_list(cards) %></main>", :page),
      Upkeep::Templates::Template.new("boards/inline", "<main><% cards.each do |card| %><span><%= card.title %></span><% end %></main>", :page),
      Upkeep::Templates::Template.new("cards/_card", "<li><%= card.title %></li>", :partial)
    ].then { |templates| Upkeep::HerbSupport::RuntimeAlignment.build_manifests(templates) }
  end
end
