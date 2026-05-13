# frozen_string_literal: true

require_relative "template_manifest"

module Upkeep
  module HerbSupport
    class ManifestDiff
      PARSE_OPTIONS = TemplateManifest::DEFAULT_PARSE_OPTIONS.merge(
        action_view_helpers: false,
        transform_conditionals: false
      ).freeze

      CONTENT_ONLY_OPERATION_TYPES = %i[
        attribute_added
        attribute_removed
        attribute_value_changed
        text_changed
      ].freeze

      Plan = Data.define(
        :path,
        :action,
        :reason,
        :topology_changed,
        :diff_identical,
        :operation_types,
        :operations,
        :old_manifest,
        :new_manifest,
        :old_topology_signature,
        :new_topology_signature,
        :error
      ) do
        def gate_passed?
          error.nil?
        end

        def to_h
          {
            path: path,
            action: action,
            reason: reason,
            topology_changed: topology_changed,
            diff_identical: diff_identical,
            operation_types: operation_types,
            operations: operations,
            old_manifest_fingerprint: old_manifest&.fingerprint,
            new_manifest_fingerprint: new_manifest&.fingerprint,
            stable_topology: old_topology_signature == new_topology_signature,
            gate_passed: gate_passed?,
            error: error
          }.compact
        end
      end

      def self.plan(path:, old_source:, new_source:, parse_options: PARSE_OPTIONS)
        new(path: path, old_source: old_source, new_source: new_source, parse_options: parse_options).plan
      end

      def initialize(path:, old_source:, new_source:, parse_options: PARSE_OPTIONS)
        @path = path
        @old_source = old_source
        @new_source = new_source
        @parse_options = parse_options
      end

      def plan
        old_manifest = build_manifest(old_source)
        new_manifest = build_manifest(new_source)
        diff_result = ::Herb.diff(old_source, new_source)
        old_signature = topology_signature(old_manifest)
        new_signature = topology_signature(new_manifest)
        action, reason, topology_changed = classify(
          diff_result: diff_result,
          old_manifest: old_manifest,
          new_manifest: new_manifest,
          old_signature: old_signature,
          new_signature: new_signature
        )

        Plan.new(
          path: path,
          action: action,
          reason: reason,
          topology_changed: topology_changed,
          diff_identical: diff_result.identical?,
          operation_types: diff_result.map { |operation| operation.type.to_s },
          operations: diff_result.map { |operation| operation_payload(operation) },
          old_manifest: old_manifest,
          new_manifest: new_manifest,
          old_topology_signature: old_signature,
          new_topology_signature: new_signature,
          error: nil
        )
      rescue StandardError => error
        Plan.new(
          path: path,
          action: "full_rebuild",
          reason: "herb_diff_failed",
          topology_changed: true,
          diff_identical: false,
          operation_types: [],
          operations: [],
          old_manifest: nil,
          new_manifest: nil,
          old_topology_signature: nil,
          new_topology_signature: nil,
          error: { class: error.class.name, message: error.message }
        )
      end

      private

      attr_reader :path, :old_source, :new_source, :parse_options

      def build_manifest(source)
        TemplateManifest.build(path: path, source: source, parse_options: parse_options)
      end

      def classify(diff_result:, old_manifest:, new_manifest:, old_signature:, new_signature:)
        return ["full_rebuild", "manifest_parse_failure", true] unless old_manifest.parse.fetch(:ok) && new_manifest.parse.fetch(:ok)
        return ["noop", "identical_source", false] if diff_result.identical?

        operation_types = diff_result.map(&:type)
        stable_topology = old_signature == new_signature

        if content_only?(operation_types) && stable_topology
          ["refresh_manifest", "content_only_stable_topology", false]
        elsif stable_topology
          ["rebuild_manifest", "dynamic_template_operation", true]
        else
          ["rebuild_manifest", "manifest_topology_changed", true]
        end
      end

      def content_only?(operation_types)
        (operation_types - CONTENT_ONLY_OPERATION_TYPES).empty?
      end

      def topology_signature(manifest)
        return { parse_ok: false } unless manifest.parse.fetch(:ok)

        {
          root_shape: manifest.root_shape.slice(:significant_children, :root_elements, :root_types, :single_root, :multi_root),
          fragment_roots: fragment_root_signature(manifest),
          render_sites: render_site_signature(manifest)
        }
      end

      def fragment_root_signature(manifest)
        manifest.frontend_tag_plan
          .select { |tag| tag.fetch(:kind) == "fragment_root" }
          .map { |tag| { tag_name: tag.fetch(:tag_name), attributes: tag.fetch(:attributes).map { |attribute| attribute.fetch(:name) } } }
      end

      def render_site_signature(manifest)
        manifest.render_nodes.map do |render_node|
          {
            kind: render_node.fetch(:kind),
            partial: render_node.fetch(:partial),
            template_path: render_node.fetch(:template_path),
            collection: render_node.fetch(:collection),
            object: render_node.fetch(:object),
            as: render_node.fetch(:as),
            locals: render_node.fetch(:locals),
            block_arguments: render_node.fetch(:block_arguments)
          }
        end
      end

      def operation_payload(operation)
        {
          type: operation.type.to_s,
          path: operation.path,
          old_node: operation.old_node&.class&.name,
          new_node: operation.new_node&.class&.name,
          old_index: operation.old_index,
          new_index: operation.new_index
        }.compact
      end
    end
  end
end
