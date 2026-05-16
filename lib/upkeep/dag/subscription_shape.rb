# frozen_string_literal: true

require "digest"
require_relative "../shared_streams"
require_relative "../version"

module Upkeep
  module DAG
    class SubscriptionShape
      DIGEST_SCOPE = "upkeep-subscription-shape"

      attr_reader :signature

      def self.from_graph(graph, request_signature: nil)
        new(signature: signature_for(request_signature, graph_component(graph)))
      end

      def self.from_components(graph_component, request_signature: nil)
        new(signature: signature_for(request_signature, graph_component))
      end

      def self.signature_for(request_signature, graph_component)
        Digest::SHA256.hexdigest([
          DIGEST_SCOPE,
          Upkeep::VERSION,
          request_signature_component(request_signature),
          graph_component
        ].inspect)
      end

      def self.request_signature_component(signature)
        return nil unless signature

        signature.respond_to?(:to_h) ? signature.to_h : signature
      end

      def self.graph_component(graph)
        {
          frames: graph.frame_nodes.map { |node| frame_component(node.id, node.payload) }.sort_by { |component| component.fetch(:id).to_s },
          dependencies: graph.dependency_nodes.map { |node| dependency_component(graph, node) }.sort_by { |component| component.fetch(:id).inspect },
          contains: graph.edges
            .select { |edge| edge.reason == :contains }
            .map { |edge| [edge.from, edge.to] }
            .sort_by(&:inspect)
        }
      end

      def self.frame_component(id, payload)
        {
          id: id,
          payload: frame_payload_component(payload)
        }
      end

      def self.frame_payload_component(payload)
        component = payload.reject { |key, _value| key.respond_to?(:to_sym) && key.to_sym == :recipe }
        component = shape_value(component)
        recipe = payload[:recipe] || payload["recipe"]
        kind = payload[:kind] || payload["kind"]
        if recipe && kind.to_s == "render_site"
          component[:shared_stream_signature] = SharedStreams.signature_for(recipe)
        end
        component
      end

      def self.dependency_component(graph, node)
        {
          id: node.id,
          dependency: shape_value(node.payload.to_h),
          owners: graph.dependency_owner_ids(node.id).sort_by(&:to_s)
        }
      end

      def self.shape_value(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).to_h { |key| [key, shape_value(value.fetch(key))] }
        when Array
          value.map { |item| shape_value(item) }
        else
          value.respond_to?(:to_h) ? shape_value(value.to_h) : value
        end
      end

      def initialize(signature:)
        @signature = signature
      end

      class Trace
        def initialize(graph_version:)
          @graph_version = graph_version
          @frames = {}
          @dependencies = {}
          @dependency_owner_ids_by_key = Hash.new { |owners, dependency_key| owners[dependency_key] = {} }
          @contains = {}
          @invalid = false
        end

        def synchronized_with?(graph)
          !@invalid && @graph_version == graph.version
        end

        def invalidate!
          @invalid = true
        end

        def record_frame(frame_id, metadata, parent_id:, graph_version:)
          return if @invalid

          @frames[frame_id] ||= SubscriptionShape.frame_component(frame_id, metadata)
          @contains[[parent_id, frame_id]] = true
          @graph_version = graph_version
        end

        def record_dependency(owner_id, dependency, graph_version:)
          return if @invalid

          dependency_cache_key = dependency.cache_key
          @dependencies[dependency_cache_key] ||= {
            id: dependency_cache_key,
            dependency: SubscriptionShape.shape_value(dependency.to_h)
          }
          @dependency_owner_ids_by_key[dependency_cache_key][owner_id] = true
          @graph_version = graph_version
        end

        def covers?(graph)
          synchronized_with?(graph) && (recorded? || graph_shape_empty?(graph))
        end

        def subscription_shape(request_signature: nil)
          SubscriptionShape.from_components(graph_component, request_signature: request_signature)
        end

        private

        def recorded?
          @frames.any? || @dependencies.any? || @contains.any?
        end

        def graph_shape_empty?(graph)
          graph.frame_nodes.empty? &&
            graph.dependency_nodes.empty? &&
            graph.edges.none? { |edge| edge.reason == :contains }
        end

        def graph_component
          {
            frames: @frames.values.sort_by { |component| component.fetch(:id).to_s },
            dependencies: @dependencies.map { |dependency_key, component| dependency_component(dependency_key, component) }
              .sort_by { |component| component.fetch(:id).inspect },
            contains: @contains.keys.sort_by(&:inspect)
          }
        end

        def dependency_component(dependency_key, component)
          component.merge(
            owners: @dependency_owner_ids_by_key.fetch(dependency_key).keys.sort_by(&:to_s)
          )
        end
      end
    end
  end
end
