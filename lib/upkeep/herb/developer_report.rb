# frozen_string_literal: true

require_relative "template_manifest"

module Upkeep
  module HerbSupport
    class DeveloperReport
      FALLBACK_ACTIONS = {
        "helper_hidden_collection" => "Move collection rendering out of helper-only HTML and into an explicit render site.",
        "manifest_runtime_mismatch" => "Inspect manifest provenance mismatches before trusting narrow updates.",
        "multi_root_partial" => "Wrap the partial in one stable root element so it can carry a fragment marker.",
        "no_herb_render_site" => "Extract updateable repeated markup into a partial render so Herb can plan a render site.",
        "page_dependency_without_narrower_frame" => "Add a fragment or render-site boundary around the data-dependent region.",
        "parse_failure" => "Fix the Herb parse error before using source-derived update addresses.",
        "parse_recovered" => "Herb recovered with non-strict parsing, but Upkeep kept narrow source-derived addresses disabled. Fix the strict warnings to enable narrow updates.",
        "preloaded_plain_data" => "Keep record identity available to the view or attach summaries to their source records."
      }.freeze

      def initialize(manifests:, proof_report: nil)
        @manifests = manifests
        @proof_report = proof_report
      end

      def to_h
        actions = template_actions + fallback_actions

        {
          summary: TemplateManifest.summary(manifests).merge(
            page_fallback_reasons: page_fallback_reasons,
            actionable_items: actions.size,
            gate_passed: actions.all? { |action| action.fetch(:message) }
          ),
          templates: manifests.map { |manifest| template_report(manifest) },
          actions: actions
        }
      end

      private

      attr_reader :manifests, :proof_report

      def template_report(manifest)
        {
          path: manifest.path,
          kind: manifest.partial? ? "partial" : "page",
          parse_ok: manifest.parse.fetch(:ok),
          parse_recovered: manifest.recovered?,
          strict_parse_errors: strict_parse_errors(manifest),
          parse_warnings: parse_warnings(manifest),
          render_sites: manifest.render_nodes.size,
          recovered_render_sites: manifest.recovery_render_nodes.size,
          fragment_root_tags: manifest.frontend_tag_plan.count { |tag| tag.fetch(:kind) == "fragment_root" },
          helper_lowered_elements: manifest.helper_lowered_elements.size,
          blockers: template_blockers(manifest)
        }
      end

      def template_actions
        manifests.flat_map do |manifest|
          template_blockers(manifest).map do |blocker|
            action = {
              source: "template",
              path: manifest.path,
              reason: blocker,
              message: template_action_message(blocker)
            }
            action[:recovered_render_sites] = manifest.recovery_render_nodes.size if blocker == "parse_recovered"
            action
          end
        end
      end

      def template_blockers(manifest)
        blockers = []
        blockers << (manifest.recovered? ? "parse_recovered" : "parse_failure") unless manifest.parse.fetch(:ok)
        blockers << "partial_without_single_root" if manifest.partial? && manifest.parse.fetch(:ok) && !manifest.root_shape.fetch(:single_root, false)
        blockers << "page_without_render_site" if !manifest.partial? && manifest.parse.fetch(:ok) && manifest.render_nodes.empty?
        blockers
      end

      def template_action_message(blocker)
        case blocker
        when "parse_failure"
          FALLBACK_ACTIONS.fetch("parse_failure")
        when "parse_recovered"
          FALLBACK_ACTIONS.fetch("parse_recovered")
        when "partial_without_single_root"
          FALLBACK_ACTIONS.fetch("multi_root_partial")
        when "page_without_render_site"
          FALLBACK_ACTIONS.fetch("no_herb_render_site")
        end
      end

      def fallback_actions
        proof_cases.flat_map do |test_case|
          test_case.fetch(:selected_targets).filter_map do |target|
            next unless target.fetch(:kind) == "page"

            fallback_reason = target[:fallback_reason]
            next unless fallback_reason

            {
              source: "proof",
              case: test_case.fetch(:name),
              target: target.fetch(:id),
              reason: fallback_reason,
              message: FALLBACK_ACTIONS.fetch(fallback_reason, "Add a narrower template boundary or keep the page fallback.")
            }
          end
        end
      end

      def proof_cases
        Array(proof_report&.fetch(:cases, []))
      end

      def page_fallback_reasons
        proof_report&.fetch(:summary, {})&.fetch(:page_fallback_reasons, {}) || {}
      end

      def strict_parse_errors(manifest)
        Array(manifest.parse[:errors])
      end

      def parse_warnings(manifest)
        warnings = Array(manifest.parse[:warnings])
        return warnings unless manifest.recovered?

        warnings + strict_parse_errors(manifest).map do |error|
          error.merge(severity: "warning", recovery: "non_strict")
        end
      end
    end
  end
end
