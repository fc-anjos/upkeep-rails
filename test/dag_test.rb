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
end
