# frozen_string_literal: true

require_relative "template_manifest"

module Upkeep
  module HerbSupport
    class SourceInstrumenter
      def initialize(manifest:)
        @manifest = manifest
      end

      def instrument(source)
        return source unless manifest.parse.fetch(:ok) || manifest.recovered?

        apply_replacements(source, replacements_for(source))
      end

      private

      attr_reader :manifest

      def replacements_for(source)
        render_site_replacements + marker_replacements(source)
      end

      def render_site_replacements
        return [] unless manifest.parse.fetch(:ok)

        manifest.render_nodes.select { |render_node| render_node.fetch(:render_site_container) }.map do |render_node|
          [
            render_node.fetch(:start_offset),
            render_node.fetch(:end_offset),
            %(<%= upkeep_frame("#{render_node.fetch(:site_id)}", manifest_path: "#{manifest.path}", manifest_fingerprint: "#{manifest.fingerprint}") { #{render_node.fetch(:expression)} } %>)
          ]
        end
      end

      def marker_replacements(source)
        frontend_tag_plan_for_instrumentation
          .filter_map { |tag| root_marker_replacement(source, tag) }
      end

      def frontend_tag_plan_for_instrumentation
        return manifest.frontend_tag_plan.select { |entry| %w[fragment_root page_root render_site].include?(entry.fetch(:kind)) } if manifest.parse.fetch(:ok)

        manifest.recovery_frontend_tag_plan.select { |entry| %w[fragment_root page_root].include?(entry.fetch(:kind)) }
      end

      def root_marker_replacement(source, tag)
        return helper_marker_replacement(source, tag) if helper_lowered_tag?(tag)

        offset = offset_for_location(source, tag.fetch(:location).fetch(:start))
        open_tag_end = source.index(">", offset)
        return unless open_tag_end

        open_tag = source[offset...open_tag_end]
        return if tag.fetch(:attributes).any? { |attribute| open_tag.include?(%(#{attribute.fetch(:name)}=)) }

        insert_at = fragment_root_insert_offset(source, offset, tag.fetch(:tag_name))
        [insert_at, insert_at, " #{attributes_source(tag.fetch(:attributes))}"]
      end

      def helper_marker_replacement(source, tag)
        return unless tag_helper_source?(tag)

        offset = offset_for_location(source, tag.fetch(:location).fetch(:start))
        erb_end = source.index("%>", offset)
        return unless erb_end

        opening = source[offset...erb_end]
        return if tag.fetch(:attributes).any? { |attribute| opening.include?(attribute.fetch(:name)) }

        block_match = /\s+do(?:\s*\|[^|]*\|)?\s*\z/.match(opening)
        return unless block_match

        before_block = opening[0...block_match.begin(0)].rstrip
        insert_at = offset + block_match.begin(0)
        [
          insert_at,
          insert_at,
          "#{helper_attribute_separator(before_block)}#{helper_attributes_source(tag.fetch(:attributes))}"
        ]
      end

      def helper_lowered_tag?(tag)
        tag.fetch(:element_source) != "HTML"
      end

      def tag_helper_source?(tag)
        [
          "ActionView::Helpers::TagHelper#tag",
          "ActionView::Helpers::TagHelper#content_tag"
        ].include?(tag.fetch(:element_source))
      end

      def helper_attribute_separator(before_block)
        return ", " if before_block.match?(/\bcontent_tag\b/)

        tag_call = before_block.match(/<%=?\s*tag\.[a-zA-Z_][a-zA-Z0-9_:-]*/)
        return " " if tag_call && before_block[tag_call.end(0)..].to_s.strip.empty?

        ", "
      end

      def helper_attributes_source(attributes)
        attributes.map do |attribute|
          %(#{attribute.fetch(:name).inspect} => #{ruby_attribute_value(attribute.fetch(:value))})
        end.join(", ")
      end

      def ruby_attribute_value(value)
        if (match = /\A<%=\s*(.*?)\s*%>\z/.match(value.to_s))
          match[1]
        else
          value.inspect
        end
      end

      def fragment_root_insert_offset(source, offset, tag_name)
        match = /\A<\s*#{Regexp.escape(tag_name)}\b/i.match(source[offset..])
        raise "could not locate fragment root tag for #{manifest.path}" unless match

        offset + match.end(0)
      end

      def attributes_source(attributes)
        attributes.map { |attribute| %(#{attribute.fetch(:name)}="#{attribute.fetch(:value)}") }.join(" ")
      end

      def apply_replacements(source, replacements)
        replacements.sort_by { |start_offset, end_offset, _replacement| [-start_offset, -end_offset] }.each_with_object(source.dup) do |(start_offset, end_offset, replacement), result|
          result[start_offset...end_offset] = replacement
        end
      end

      def offset_for_location(source, position)
        line_offsets(source).fetch(position.fetch(:line) - 1) + position.fetch(:column)
      end

      def line_offsets(source)
        offsets = [0]
        source.each_line(chomp: false).with_index do |line, index|
          offsets[index + 1] = offsets[index] + line.bytesize
        end
        offsets
      end
    end
  end
end
