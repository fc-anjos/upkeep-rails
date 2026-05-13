# frozen_string_literal: true

module Upkeep
  module HerbSupport
    class FallbackAnalyzer
      def initialize(manifests:, alignment_report:)
        @manifests_by_path = manifests.to_h { |manifest| [manifest.path, manifest] }
        @alignment_report = alignment_report
      end

      def target_payload(graph:, target:, changes:)
        fallback_reason = fallback_reason_for(graph: graph, target: target, changes: changes)
        payload = { kind: target.kind, id: target.id, reason: target.reason }
        payload[:fallback_reason] = fallback_reason if fallback_reason
        payload
      end

      def fallback_reason_for(graph:, target:, changes:)
        return unless target.kind == "page"

        frame = graph.node(target.id)
        template = frame.payload[:template]
        manifest = manifests_by_path[template]

        return "manifest_runtime_mismatch" if manifest_runtime_mismatch?
        return manifest_reason(manifest) unless manifest&.parse&.fetch(:ok)
        return "preloaded_plain_data" if request_owned_matching_dependency?(graph, changes)
        return "multi_root_partial" if multi_root_child_partial?(graph, frame)
        return "helper_hidden_collection" if helper_hidden_collection?(graph, frame, manifest)
        return "no_herb_render_site" if manifest.render_nodes.empty?

        "page_dependency_without_narrower_frame"
      end

      private

      attr_reader :manifests_by_path, :alignment_report

      def manifest_runtime_mismatch?
        summary = alignment_report.fetch(:summary)
        summary.fetch(:frame_deopt_reasons).any? || summary.fetch(:selected_target_deopt_reasons).any?
      end

      def manifest_reason(manifest)
        return "manifest_missing" unless manifest

        "parse_failure"
      end

      def request_owned_matching_dependency?(graph, changes)
        graph.dependency_node_ids_matching(changes).any? do |dependency_node_id|
          graph.dependency_owner_ids(dependency_node_id).include?(Runtime::Recorder::REQUEST_NODE_ID)
        end
      end

      def multi_root_child_partial?(graph, frame)
        child_fragment_frames(graph, frame).any? do |child|
          manifest = manifests_by_path[child.payload[:template]]
          manifest && manifest.root_shape.fetch(:multi_root, false)
        end
      end

      def helper_hidden_collection?(graph, frame, manifest)
        manifest.render_nodes.empty? &&
          child_fragment_frames(graph, frame).any? &&
          graph.dependencies_for(frame.id).any? { |dependency| dependency.source == :active_record_collection }
      end

      def child_fragment_frames(graph, frame)
        graph.outgoing_edges(frame.id, reason: :contains).filter_map do |edge|
          child = graph.node(edge.to)
          child if child.kind == :frame && child.payload.fetch(:kind) == "fragment"
        end
      end
    end
  end
end
