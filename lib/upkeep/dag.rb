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
        @edge_keys = {}
        @dependencies_by_node = Hash.new { |hash, key| hash[key] = [] }
        @dependency_cache_keys_by_node = Hash.new { |hash, key| hash[key] = {} }
      end

      def add_node(id, kind:, payload: {})
        nodes[id] ||= Node.new(id, kind, payload)
      end

      def add_edge(from, to, reason:)
        key = edge_key(from, to, reason)
        return if @edge_keys[key]

        @edge_keys[key] = true
        edges << Edge.new(from, to, reason)
      end

      def add_dependency(owner_id, dependency)
        dependency_cache_key = dependency.cache_key
        add_node(owner_id, kind: :unknown) unless nodes.key?(owner_id)
        add_node(dependency_cache_key, kind: :dependency, payload: dependency)
        add_edge(owner_id, dependency_cache_key, reason: :depends_on)
        dependency_cache_keys = @dependency_cache_keys_by_node[owner_id]
        return if dependency_cache_keys.key?(dependency_cache_key)

        dependency_cache_keys[dependency_cache_key] = true
        @dependencies_by_node[owner_id] << dependency
      end

      def dependencies_for(node_id)
        @dependencies_by_node[node_id]
      end

      def node(id)
        nodes.fetch(id)
      end

      def node?(id)
        nodes.key?(id)
      end

      def outgoing_edges(from, reason: nil)
        edges.select { |edge| edge.from == from && (reason.nil? || edge.reason == reason) }
      end

      def incoming_edges(to, reason: nil)
        edges.select { |edge| edge.to == to && (reason.nil? || edge.reason == reason) }
      end

      def dependency_owner_ids(dependency_node_id)
        incoming_edges(dependency_node_id, reason: :depends_on).map(&:from)
      end

      def dependency_node_ids_matching(changes)
        dependency_nodes.filter_map do |node|
          node.id if changes.any? { |change| node.payload.matches_change?(change) }
        end
      end

      def nearest_frame_nodes_from(node_id)
        current = node(node_id)
        return [current] if current.kind == :frame

        queue = outgoing_edges(node_id, reason: :contains).map(&:to)
        visited = {}
        frames = []

        until queue.empty?
          id = queue.shift
          next if visited[id]

          visited[id] = true
          current = node(id)
          if current.kind == :frame
            frames << current
          else
            queue.concat(outgoing_edges(id, reason: :contains).map(&:to))
          end
        end

        frames
      end

      def ancestor_node_ids(node_id)
        ancestors = []
        current = node_id

        while (edge = incoming_edges(current, reason: :contains).first)
          ancestors << edge.from
          current = edge.from
        end

        ancestors
      end

      def contained_by?(descendant_id, ancestor_id)
        ancestor_node_ids(descendant_id).include?(ancestor_id)
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
          manifest_attached_frames: frame_nodes.count { |node| node.payload[:manifest_path] },
          dependencies: dependency_nodes.size,
          containment_edges: edges.count { |edge| edge.reason == :contains },
          dependency_edges: edges.count { |edge| edge.reason == :depends_on },
          replay_recipes: frame_nodes.count { |node| node.payload[:recipe] },
          replay_recipe_kinds: frame_nodes.filter_map { |node| node.payload[:recipe]&.kind }.map(&:to_s).uniq.sort,
          dependency_sources: dependency_nodes.map { |node| node.payload.source.to_s }.uniq.sort
        }
      end

      def report
        {
          summary: summary,
          frames: frame_reports,
          dependencies: dependency_reports,
          edges: edges.map(&:to_h)
        }
      end

      def to_h
        {
          nodes: nodes.values.map { |node| serialize_node(node) },
          edges: edges.map(&:to_h)
        }
      end

      def self.from_h(snapshot)
        snapshot = symbolize_keys(snapshot)
        graph = new
        graph.nodes.clear
        graph.edges.clear

        snapshot.fetch(:nodes).each do |node_snapshot|
          node_snapshot = symbolize_keys(node_snapshot)
          kind = node_snapshot.fetch(:kind).to_sym
          graph.nodes[node_snapshot.fetch(:id)] = Node.new(
            node_snapshot.fetch(:id),
            kind,
            deserialize_payload(kind, node_snapshot.fetch(:payload, {}))
          )
        end

        snapshot.fetch(:edges).each do |edge_snapshot|
          edge_snapshot = symbolize_keys(edge_snapshot)
          graph.add_edge(
            edge_snapshot.fetch(:from),
            edge_snapshot.fetch(:to),
            reason: edge_snapshot.fetch(:reason).to_sym
          )
        end

        graph.send(:rebuild_dependency_index)
        graph
      end

      def frame_reports
        frame_nodes.map do |node|
          {
            id: node.id,
            kind: node.payload.fetch(:kind),
            template: node.payload[:template],
            site_id: node.payload[:site_id],
            manifest_path: node.payload[:manifest_path],
            manifest_fingerprint: node.payload[:manifest_fingerprint],
            locals: node.payload[:locals],
            contains: outgoing_edges(node.id, reason: :contains).map(&:to),
            dependencies: dependencies_for(node.id).map(&:to_h),
            replay_recipe: node.payload[:recipe]&.to_h
          }.compact
        end
      end

      def dependency_reports
        dependency_nodes.map do |node|
          {
            id: node.id,
            dependency: node.payload.to_h,
            owners: dependency_owner_ids(node.id)
          }
        end
      end

      private

      def rebuild_dependency_index
        @dependencies_by_node = Hash.new { |hash, key| hash[key] = [] }
        @dependency_cache_keys_by_node = Hash.new { |hash, key| hash[key] = {} }

        edges.each do |edge|
          next unless edge.reason == :depends_on

          dependency = nodes.fetch(edge.to).payload
          dependency_cache_keys = @dependency_cache_keys_by_node[edge.from]
          next if dependency_cache_keys.key?(dependency.cache_key)

          dependency_cache_keys[dependency.cache_key] = true
          @dependencies_by_node[edge.from] << dependency
        end
      end

      def edge_key(from, to, reason)
        [from, to, reason]
      end

      class << self
        def deserialize_payload(kind, payload)
          payload = symbolize_keys(payload)

          case kind
          when :dependency
            Dependencies.from_h(payload)
          when :frame
            deserialize_frame_payload(payload)
          else
            payload
          end
        end

        def deserialize_frame_payload(payload)
          payload.each_with_object({}) do |(key, value), frame_payload|
            frame_payload[key] = key == :recipe && value ? Replay::Recipe.from_h(value) : value
          end
        end

        def symbolize_keys(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested_value), result|
              normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
              result[normalized_key] = symbolize_keys(nested_value)
            end
          when Array
            value.map { |nested_value| symbolize_keys(nested_value) }
          else
            value
          end
        end
      end

      def serialize_node(node)
        {
          id: node.id,
          kind: node.kind,
          payload: serialize_payload(node)
        }
      end

      def serialize_payload(node)
        case node.kind
        when :dependency
          node.payload.to_h
        when :frame
          node.payload.each_with_object({}) do |(key, value), frame_payload|
            frame_payload[key] = key == :recipe && value ? value.to_h : value
          end
        else
          node.payload
        end
      end
    end
  end
end
