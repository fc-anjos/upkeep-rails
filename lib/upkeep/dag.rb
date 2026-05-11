# frozen_string_literal: true

module Upkeep
  module DAG
    Node = Data.define(:id, :kind, :payload)
    Edge = Data.define(:from, :to, :reason)

    class Graph
      attr_reader :nodes, :edges

      def initialize
        @nodes = {}
        @edges = []
        @dependencies_by_node = Hash.new { |hash, key| hash[key] = [] }
      end

      def add_node(id, kind:, payload: {})
        nodes[id] ||= Node.new(id, kind, payload)
      end

      def add_edge(from, to, reason:)
        edge = Edge.new(from, to, reason)
        edges << edge unless edges.include?(edge)
      end

      def add_dependency(owner_id, dependency)
        add_node(owner_id, kind: :unknown) unless nodes.key?(owner_id)
        add_node(dependency.cache_key, kind: :dependency, payload: dependency)
        add_edge(owner_id, dependency.cache_key, reason: :depends_on)
        dependencies = @dependencies_by_node[owner_id]
        dependencies << dependency unless dependencies.any? { |existing| existing.cache_key == dependency.cache_key }
      end

      def dependencies_for(node_id)
        @dependencies_by_node[node_id]
      end

      def frame_nodes
        nodes.values.select { |node| node.kind == :frame }
      end

      def dependency_nodes
        nodes.values.select { |node| node.kind == :dependency }
      end

      def summary
        {
          nodes: nodes.size,
          edges: edges.size,
          frames: frame_nodes.size,
          dependencies: dependency_nodes.size,
          dependency_sources: dependency_nodes.map { |node| node.payload.source.to_s }.uniq.sort
        }
      end
    end
  end
end
