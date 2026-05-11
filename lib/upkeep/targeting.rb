# frozen_string_literal: true

require "digest"
require "nokogiri"

module Upkeep
  module Targeting
    Target = Data.define(:kind, :id, :reason)
    Patch = Data.define(:target, :html)

    class Selector
      def select(recorder, changes)
        page_targets = []
        render_site_targets = []
        fragment_targets = []

        recorder.graph.frame_nodes.each do |node|
          frame_id = node.id
          dependencies = recorder.graph.dependencies_for(frame_id)

          if frame_id.start_with?("page:") && dependencies_intersect_change?(dependencies, changes)
            page_targets << Target.new("page", frame_id, "page frame dependency matched committed change")
          elsif frame_id.start_with?("site:") && dependencies_intersect_change?(dependencies, changes)
            render_site_targets << Target.new("render_site", frame_id.delete_prefix("site:"), "render-site dependency matched committed change")
          elsif frame_id.start_with?("fragment:") && dependencies_intersect_narrow_change?(dependencies, changes)
            fragment_targets << Target.new("fragment", frame_id, "record attribute read matched committed attributes")
          end
        end

        return uniq_targets(page_targets) if page_targets.any?
        return uniq_targets(render_site_targets) if render_site_targets.any?
        return uniq_targets(fragment_targets) if fragment_targets.any?

        if dependencies_intersect_change?(recorder.graph.dependencies_for(Runtime::Recorder::REQUEST_NODE_ID), changes)
          page_id = recorder.frame_metadata.keys.find { |id| id.start_with?("page:") }
          return [Target.new("page", page_id, "request-level dependency matched committed change")]
        end

        []
      end

      def dependencies_intersect_change?(dependencies, changes)
        dependencies.any? { |dependency| changes.any? { |change| dependency.matches_change?(change) } }
      end

      def dependencies_intersect_narrow_change?(dependencies, changes)
        dependencies.any? do |dependency|
          dependency.narrow_frame_safe? && changes.any? { |change| dependency.matches_change?(change) }
        end
      end

      private

      def uniq_targets(targets)
        targets.uniq { |target| [target.kind, target.id] }
      end
    end

    class Patcher
      def initialize(html)
        @fragment = Nokogiri::HTML5.fragment(html)
      end

      def apply(patches)
        patches.each { |patch| apply_patch(patch) }
        fragment.to_html
      end

      private

      attr_reader :fragment

      def apply_patch(patch)
        node = node_for(patch.target)
        raise "target not found in current DOM: #{patch.target.inspect}" unless node

        replacement = Nokogiri::HTML5.fragment(patch.html).children.find { |child| child.element? }
        node.replace(replacement)
      end

      def node_for(target)
        case target.kind
        when "page"
          fragment.at_css(%([data-upkeep-page-frame="#{css_escape(target.id)}"]))
        when "fragment"
          fragment.at_css(%([data-upkeep-frame="#{css_escape(target.id)}"]))
        when "render_site"
          fragment.at_css(%(upkeep-render-site[data-upkeep-render-site="#{css_escape(target.id)}"]))
        end
      end

      def css_escape(value)
        value.to_s.gsub("\\", "\\\\\\").gsub('"', '\"')
      end
    end

    module Extraction
      module_function

      def patches_from_full_rerender(full_html, targets)
        targets.map { |target| Patch.new(target, extract_target_html(full_html, target)) }
      end

      def extract_target_html(html, target)
        fragment = Nokogiri::HTML5.fragment(html)
        node = case target.kind
        when "page"
          fragment.at_css(%([data-upkeep-page-frame="#{css_escape(target.id)}"]))
        when "fragment"
          fragment.at_css(%([data-upkeep-frame="#{css_escape(target.id)}"]))
        when "render_site"
          fragment.at_css(%(upkeep-render-site[data-upkeep-render-site="#{css_escape(target.id)}"]))
        end

        raise "target not found in full rerender: #{target.inspect}" unless node

        node.to_html
      end

      def normalize_html(html)
        Nokogiri::HTML5.fragment(html).to_html
      end

      def digest_html(html)
        Digest::SHA256.hexdigest(normalize_html(html))
      end

      def frame_id_for(target)
        target.kind == "render_site" ? "site:#{target.id}" : target.id
      end

      def css_escape(value)
        value.to_s.gsub("\\", "\\\\\\").gsub('"', '\"')
      end
    end
  end
end
