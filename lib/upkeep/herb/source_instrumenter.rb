# frozen_string_literal: true

require_relative "template_manifest"

module Upkeep
  module HerbSupport
    class SourceInstrumenter
      def initialize(manifest:)
        @manifest = manifest
      end

      def instrument(source)
        return source unless manifest.parse.fetch(:ok)

        apply_replacements(source, replacements_for(source))
      end

      private

      attr_reader :manifest

      def replacements_for(source)
        render_site_replacements + fragment_root_replacements(source)
      end

      def render_site_replacements
        manifest.render_nodes.select { |render_node| render_node.fetch(:collection) }.map do |render_node|
          [
            render_node.fetch(:start_offset),
            render_node.fetch(:end_offset),
            %(<%= render_site("#{render_node.fetch(:site_id)}", manifest_path: "#{manifest.path}", manifest_fingerprint: "#{manifest.fingerprint}") { #{render_node.fetch(:expression)} } %>)
          ]
        end
      end

      def fragment_root_replacements(source)
        tag = manifest.frontend_tag_plan.find { |entry| entry.fetch(:kind) == "fragment_root" }
        return [] unless tag

        offset = offset_for_location(source, tag.fetch(:location).fetch(:start))
        open_tag_end = source.index(">", offset)
        return [] unless open_tag_end

        open_tag = source[offset...open_tag_end]
        return [] if open_tag.include?("data-upkeep-frame=")

        insert_at = fragment_root_insert_offset(source, offset, tag.fetch(:tag_name))
        [[insert_at, insert_at, " #{attributes_source(tag.fetch(:attributes))}"]]
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
