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
        new(signature: signature_for_terms(request_signature, graph_terms(graph)))
      end

      def self.from_components(graph_component, request_signature: nil)
        new(signature: signature_for_terms(request_signature, terms_for_component(graph_component)))
      end

      def self.from_terms(graph_terms, request_signature: nil)
        new(signature: signature_for_terms(request_signature, graph_terms))
      end

      def self.from_trace_digest(trace_digest, request_signature: nil)
        new(signature: signature_for_trace_digest(request_signature, trace_digest))
      end

      def self.signature_for_terms(request_signature, graph_terms)
        digest = Digest::SHA256.new
        digest.update(DIGEST_SCOPE)
        digest.update("\0")
        digest.update(Upkeep::VERSION)
        digest.update("\0")
        digest.update(canonical_value(request_signature_component(request_signature)))
        %i[frames dependencies contains].each do |group|
          digest.update("\0")
          digest.update(group.to_s)
          Array(graph_terms[group]).each do |term|
            digest.update("\0")
            digest.update(term)
          end
        end
        digest.hexdigest
      end

      def self.signature_for_trace_digest(request_signature, trace_digest)
        digest = Digest::SHA256.new
        digest.update(DIGEST_SCOPE)
        digest.update("\0")
        digest.update(Upkeep::VERSION)
        digest.update("\0")
        digest.update(canonical_value(request_signature_component(request_signature)))
        digest.update("\0")
        digest.update(trace_digest)
        digest.hexdigest
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

      def self.graph_terms(graph)
        {
          frames: graph.frame_nodes.map { |node| frame_term(node.id, node.payload) },
          dependencies: graph.dependency_nodes.map { |node| dependency_term(node.id, node.payload, graph.dependency_owner_ids(node.id)) },
          contains: graph.edges
            .select { |edge| edge.reason == :contains }
            .map { |edge| contains_term(edge.from, edge.to) }
        }
      end

      def self.terms_for_component(graph_component)
        {
          frames: graph_component.fetch(:frames).map { |component| canonical_term(:frame, component.fetch(:id), component.fetch(:payload)) },
          dependencies: graph_component.fetch(:dependencies).map do |component|
            canonical_term(:dependency, component.fetch(:id), component.fetch(:dependency), component.fetch(:owners))
          end,
          contains: graph_component.fetch(:contains).map { |from, to| contains_term(from, to) }
        }
      end

      def self.frame_component(id, payload)
        {
          id: id,
          payload: frame_payload_component(payload)
        }
      end

      def self.frame_term(id, payload)
        canonical_term(:frame, id, frame_payload_component(payload))
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

      def self.dependency_term(id, dependency, owners)
        canonical_term(:dependency, id, dependency.to_h, owners.sort_by(&:to_s))
      end

      def self.contains_term(from, to)
        canonical_term(:contains, from, to)
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

      def self.canonical_term(*parts)
        parts.map { |part| canonical_value(part) }.join("\0")
      end

      def self.canonical_value(value)
        shape_value(value).inspect
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
          @frame_terms_by_id = {}
          @dependency_payloads_by_key = {}
          @contains_terms_by_edge = {}
          @digest = Digest::SHA256.new
          @digest.update("subscription-shape-trace")
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
          unless @frame_terms_by_id.key?(frame_id)
            @frame_terms_by_id[frame_id] = SubscriptionShape.frame_term(frame_id, metadata)
            record_digest_term(:frame, @frame_terms_by_id.fetch(frame_id))
          end
          unless @contains_terms_by_edge.key?([parent_id, frame_id])
            @contains_terms_by_edge[[parent_id, frame_id]] = SubscriptionShape.contains_term(parent_id, frame_id)
            record_digest_term(:contains, @contains_terms_by_edge.fetch([parent_id, frame_id]))
          end
          @graph_version = graph_version
        end

        def record_dependency(owner_id, dependency, graph_version:)
          return if @invalid

          dependency_cache_key = dependency.cache_key
          dependency_payload = SubscriptionShape.shape_value(dependency.to_h)
          @dependencies[dependency_cache_key] ||= {
            id: dependency_cache_key,
            dependency: dependency_payload
          }
          unless @dependency_payloads_by_key.key?(dependency_cache_key)
            @dependency_payloads_by_key[dependency_cache_key] = dependency_payload
            record_digest_term(:dependency, SubscriptionShape.canonical_term(:dependency, dependency_cache_key, dependency_payload))
          end
          unless @dependency_owner_ids_by_key[dependency_cache_key].key?(owner_id)
            @dependency_owner_ids_by_key[dependency_cache_key][owner_id] = true
            record_digest_term(:dependency_owner, SubscriptionShape.canonical_term(:dependency_owner, dependency_cache_key, owner_id))
          end
          @graph_version = graph_version
        end

        def covers?(graph)
          synchronized_with?(graph) && (recorded? || graph_shape_empty?(graph))
        end

        def subscription_shape(request_signature: nil)
          SubscriptionShape.from_trace_digest(@digest.hexdigest, request_signature: request_signature)
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

        def record_digest_term(kind, term)
          @digest.update("\0")
          @digest.update(kind.to_s)
          @digest.update("\0")
          @digest.update(term)
        end
      end
    end
  end
end
