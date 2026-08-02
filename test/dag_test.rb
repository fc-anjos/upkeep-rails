# frozen_string_literal: true

require "test_helper"

class DAGTest < Minitest::Test
  def test_duplicate_edges_and_dependencies_are_indexed_once
    graph = Upkeep::DAG::Graph.new
    dependency = Upkeep::Dependencies::ActiveRecordAttribute.new(
      table: "cards",
      id: 1,
      attribute: "title",
      model: "Card"
    )

    2.times do
      graph.add_edge(:request, "fragment:card:1", reason: :contains)
      graph.add_dependency("fragment:card:1", dependency)
    end

    assert_equal 2, graph.edges.size
    assert_equal [dependency], graph.dependencies_for("fragment:card:1")
  end

  def test_deserialized_graph_keeps_edge_and_dependency_indexes
    graph = Upkeep::DAG::Graph.new
    dependency = Upkeep::Dependencies::ActiveRecordAttribute.new(
      table: "cards",
      id: 1,
      attribute: "title",
      model: "Card"
    )
    graph.add_dependency("fragment:card:1", dependency)

    restored = Upkeep::DAG::Graph.from_h(graph.to_h)
    restored.add_dependency("fragment:card:1", dependency)

    assert_equal 1, restored.edges.size
    assert_equal [dependency.cache_key], restored.dependencies_for("fragment:card:1").map(&:cache_key)
  end

  def test_replacing_a_subgraph_keeps_siblings_and_drops_old_dependencies
    original = Upkeep::DAG::Graph.new
    original.add_node("request", kind: :request)
    original.add_node("page", kind: :frame, payload: { kind: "page" })
    original.add_node("turbo_frame:cards", kind: :frame, payload: { kind: "turbo_frame", target_id: "cards" })
    original.add_node("turbo_frame:summary", kind: :frame, payload: { kind: "turbo_frame", target_id: "summary" })
    original.add_edge("request", "page", reason: :contains)
    original.add_edge("page", "turbo_frame:cards", reason: :contains)
    original.add_edge("page", "turbo_frame:summary", reason: :contains)
    original.add_dependency("page", attribute_dependency("shell"))
    original.add_dependency("turbo_frame:cards", attribute_dependency("old"))
    original.add_dependency("turbo_frame:summary", attribute_dependency("sibling"))

    replacement = Upkeep::DAG::Graph.new
    replacement.add_node("request", kind: :request)
    replacement.add_node("response", kind: :frame, payload: { kind: "page" })
    replacement.add_node("turbo_frame:cards", kind: :frame, payload: { kind: "turbo_frame", target_id: "cards" })
    replacement.add_edge("request", "response", reason: :contains)
    replacement.add_edge("response", "turbo_frame:cards", reason: :contains)
    replacement.add_dependency("turbo_frame:cards", attribute_dependency("new"))

    composed = original.replace_subgraph("turbo_frame:cards", replacement)

    assert_equal ["shell"], composed.dependencies_for("page").map { |dependency| dependency.key.fetch(:attribute) }
    assert_equal ["sibling"], composed.dependencies_for("turbo_frame:summary").map { |dependency| dependency.key.fetch(:attribute) }
    assert_equal ["new"], composed.dependencies_for("turbo_frame:cards").map { |dependency| dependency.key.fetch(:attribute) }
    refute composed.dependency_nodes.any? { |node| node.payload.key.fetch(:attribute) == "old" }
    assert_equal ["turbo_frame:cards", "turbo_frame:summary"],
      composed.outgoing_edges("page", reason: :contains).map(&:to).sort
    refute composed.node?("response")
  end

  def test_attaching_a_subgraph_adds_a_sibling_scope
    original = Upkeep::DAG::Graph.new
    original.add_node("request", kind: :request)
    original.add_node("turbo_frame:cards", kind: :frame, payload: { kind: "turbo_frame", target_id: "cards" })
    original.add_edge("request", "turbo_frame:cards", reason: :contains)
    original.add_dependency("turbo_frame:cards", attribute_dependency("cards"))

    replacement = Upkeep::DAG::Graph.new
    replacement.add_node("request", kind: :request)
    replacement.add_node("response", kind: :frame, payload: { kind: "page" })
    replacement.add_node("turbo_frame:summary", kind: :frame, payload: { kind: "turbo_frame", target_id: "summary" })
    replacement.add_edge("request", "response", reason: :contains)
    replacement.add_edge("response", "turbo_frame:summary", reason: :contains)
    replacement.add_dependency("turbo_frame:summary", attribute_dependency("summary"))

    composed = original.attach_subgraph(
      "turbo_frame:summary",
      replacement,
      parent_id: "request"
    )

    assert_equal ["turbo_frame:cards", "turbo_frame:summary"],
      composed.outgoing_edges("request", reason: :contains).map(&:to).sort
    assert_equal ["cards"], composed.dependencies_for("turbo_frame:cards").map { |dependency| dependency.key.fetch(:attribute) }
    assert_equal ["summary"], composed.dependencies_for("turbo_frame:summary").map { |dependency| dependency.key.fetch(:attribute) }
    refute composed.node?("response")
  end

  private

  def attribute_dependency(attribute)
    Upkeep::Dependencies::ActiveRecordAttribute.new(
      table: "cards",
      id: 1,
      attribute: attribute,
      model: "Card"
    )
  end
end
