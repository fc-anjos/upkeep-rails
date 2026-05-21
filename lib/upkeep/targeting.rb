# frozen_string_literal: true

require "digest"
require "nokogiri"

module Upkeep
  module Targeting
    Target = Data.define(:kind, :id, :reason)
    Patch = Data.define(:target, :html)

    class Selector
      def select(recorder, changes)
        graph = recorder.graph

        frame_nodes =
          graph.dependency_node_ids_matching(changes)
            .flat_map { |dependency_id| graph.dependency_owner_ids(dependency_id) }
            .flat_map { |owner_id| graph.nearest_frame_nodes_from(owner_id) }

        uniq_targets(remove_contained_frames(graph, frame_nodes).filter_map { |frame| target_for_frame(frame) })
      end

      private

      def remove_contained_frames(graph, frames)
        frames.uniq(&:id).reject do |frame|
          frames.any? { |candidate| candidate.id != frame.id && graph.contained_by?(frame.id, candidate.id) }
        end
      end

      def target_for_frame(frame)
        case frame.payload.fetch(:kind)
        when "page"
          Target.new("page", frame.id, "page frame dependency matched committed change")
        when "render_site"
          Target.new("render_site", frame.payload.fetch(:site_id), "render-site dependency matched committed change")
        when "fragment"
          Target.new("fragment", frame.id, "record attribute read matched committed attributes")
        end
      end

      def uniq_targets(targets)
        targets.uniq { |target| [target.kind, target.id] }
      end
    end

    class Patcher
      def initialize(html)
        @fragment = Extraction.parse_html(html)
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

        replacement = replacement_for(patch)
        node.replace(replacement)
      end

      def node_for(target)
        Extraction.node_for(fragment, target)
      end

      def replacement_for(patch)
        parsed = Extraction.parse_html(patch.html)
        Extraction.node_for(parsed, patch.target) ||
          parsed.children.find { |child| child.element? } ||
          parsed.at_css("body > *")
      end
    end

    module Extraction
      module_function

      def patches_from_full_rerender(full_html, targets)
        targets.map { |target| Patch.new(target, extract_target_html(full_html, target)) }
      end

      def extract_target_html(html, target)
        fragment = parse_html(html)
        node = node_for(fragment, target)

        raise "target not found in full rerender: #{target.inspect}" unless node

        node.to_html
      end

      def node_for(fragment, target)
        case target.kind
        when "page"
          fragment.at_css(%([data-upkeep-page-frame="#{css_escape(target.id)}"]))
        when "fragment"
          fragment.at_css(%([data-upkeep-frame="#{css_escape(target.id)}"]))
        when "render_site"
          fragment.at_css(%([data-upkeep-render-site="#{css_escape(target.id)}"]))
        end
      end

      def normalize_html(html)
        parse_html(html).to_html
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

      def parse_html(html)
        source = html.to_s

        if source.match?(/\A\s*(?:<!doctype\b[^>]*>\s*)?<html[\s>]/i)
          Nokogiri::HTML5.parse(source)
        else
          Nokogiri::HTML5.fragment(source)
        end
      end
    end
  end
end
