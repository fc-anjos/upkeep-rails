# frozen_string_literal: true

require_relative "template_manifest"

module Upkeep
  module HerbSupport
    class RuntimeAlignment
      PARSE_OPTIONS = TemplateManifest::DEFAULT_PARSE_OPTIONS.merge(
        action_view_helpers: false,
        transform_conditionals: false
      ).freeze

      def self.build_manifests(templates, parse_options: PARSE_OPTIONS)
        templates.map do |template|
          TemplateManifest.build(
            path: template.name,
            source: template.source,
            parse_options: parse_options
          )
        end
      end

      def initialize(manifests:)
        @manifests_by_path = manifests.to_h { |manifest| [manifest.path, manifest] }
        @render_sites_by_id = manifests.each_with_object({}) do |manifest, index|
          manifest.render_nodes.each { |render_node| index[render_node.fetch(:site_id)] = [manifest, render_node] }
        end
      end

      def report(graph:, selected_targets: [])
        frames = graph.frame_nodes.map { |frame| frame_alignment(frame) }
        targets = selected_targets.map { |target| target_alignment(graph, target) }

        {
          summary: summary(frames, targets),
          frames: frames,
          selected_targets: targets
        }
      end

      private

      attr_reader :manifests_by_path, :render_sites_by_id

      def summary(frames, targets)
        critical_frames = frames.select { |frame| %w[fragment render_site].include?(frame.fetch(:kind)) }
        unmatched_frames = frames.reject { |frame| frame.fetch(:matched) }
        unmatched_targets = targets.reject { |target| target.fetch(:matched) }

        {
          frames: frames.size,
          matched_frames: frames.count { |frame| frame.fetch(:matched) },
          unmatched_frames: unmatched_frames.size,
          render_site_frames: frames.count { |frame| frame.fetch(:kind) == "render_site" },
          matched_render_site_frames: frames.count { |frame| frame.fetch(:kind) == "render_site" && frame.fetch(:matched) },
          fragment_frames: frames.count { |frame| frame.fetch(:kind) == "fragment" },
          matched_fragment_frames: frames.count { |frame| frame.fetch(:kind) == "fragment" && frame.fetch(:matched) },
          selected_targets: targets.size,
          matched_selected_targets: targets.count { |target| target.fetch(:matched) },
          frame_deopt_reasons: unmatched_frames.filter_map { |frame| frame[:deopt_reason] }.tally,
          selected_target_deopt_reasons: unmatched_targets.filter_map { |target| target[:deopt_reason] }.tally,
          gate_passed: critical_frames.all? { |frame| frame.fetch(:matched) || frame[:deopt_reason] } &&
            targets.all? { |target| target.fetch(:matched) || target[:deopt_reason] }
        }
      end

      def target_alignment(graph, target)
        frame_id = frame_id_for(target)
        unless graph.node?(frame_id)
          return {
            kind: target.kind,
            id: target.id,
            frame_id: frame_id,
            matched: false,
            deopt_reason: "runtime_frame_missing"
          }
        end

        frame_alignment(graph.node(frame_id)).merge(
          target_kind: target.kind,
          target_id: target.id,
          target_reason: target.reason
        )
      end

      def frame_alignment(frame)
        case frame.payload.fetch(:kind)
        when "page"
          template_alignment(frame)
        when "fragment"
          fragment_alignment(frame)
        when "render_site"
          render_site_alignment(frame)
        else
          {
            id: frame.id,
            kind: frame.payload.fetch(:kind),
            matched: false,
            deopt_reason: "unknown_runtime_frame_kind"
          }
        end
      end

      def template_alignment(frame)
        template = frame.payload[:template]
        manifest = manifests_by_path[template]
        matched = manifest&.parse&.fetch(:ok, false)

        {
          id: frame.id,
          kind: "page",
          template: template,
          manifest_path: manifest&.path,
          matched: matched,
          deopt_reason: matched ? nil : template_deopt_reason(template, manifest)
        }.compact
      end

      def fragment_alignment(frame)
        template = frame.payload[:template]
        manifest = manifests_by_path[template]
        matched = manifest&.parse&.fetch(:ok, false) &&
          manifest.partial? &&
          manifest.root_shape.fetch(:single_root, false)

        {
          id: frame.id,
          kind: "fragment",
          template: template,
          manifest_path: manifest&.path,
          matched: matched,
          deopt_reason: matched ? nil : fragment_deopt_reason(template, manifest)
        }.compact
      end

      def render_site_alignment(frame)
        site_id = frame.payload[:site_id]
        manifest, render_node = render_sites_by_id[site_id]
        matched = !!render_node

        {
          id: frame.id,
          kind: "render_site",
          site_id: site_id,
          manifest_path: manifest&.path,
          location: render_node&.fetch(:location),
          matched: matched,
          deopt_reason: matched ? nil : "render_site_missing_from_manifest"
        }.compact
      end

      def template_deopt_reason(template, manifest)
        return "manifest_missing" unless template
        return "manifest_missing" unless manifest
        return "manifest_parse_failed" unless manifest.parse.fetch(:ok)

        "manifest_not_eligible"
      end

      def fragment_deopt_reason(template, manifest)
        return "manifest_missing" unless template
        return "manifest_missing" unless manifest
        return "manifest_parse_failed" unless manifest.parse.fetch(:ok)
        return "manifest_not_partial" unless manifest.partial?
        return "partial_not_single_root" unless manifest.root_shape.fetch(:single_root, false)

        "manifest_not_eligible"
      end

      def frame_id_for(target)
        target.kind == "render_site" ? "site:#{target.id}" : target.id
      end
    end
  end
end
