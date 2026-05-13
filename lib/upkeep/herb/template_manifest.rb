# frozen_string_literal: true

require "digest"
require_relative "../herb_loader"

module Upkeep
  module HerbSupport
    class TemplateManifest
      DEFAULT_PARSE_OPTIONS = {
        strict: true,
        track_whitespace: true,
        render_nodes: true,
        action_view_helpers: true,
        transform_conditionals: true
      }.freeze

      EMPTY_ROOT_SHAPE = {
        significant_children: 0,
        root_elements: 0,
        single_root: false,
        multi_root: false
      }.freeze

      attr_reader :path, :parse, :root_shape, :frontend_tag_plan, :render_nodes, :helper_lowered_elements

      def self.build(path:, source:, parse_options: DEFAULT_PARSE_OPTIONS)
        parse_result = ::Herb.parse(source, **parse_options)
        parse = parse_status(parse_result)
        visitor = Visitor.new(path: path, source: source)
        parse_result.value&.accept(visitor) if parse.fetch(:ok)

        new(
          path: path,
          parse: parse,
          root_shape: visitor.root_shape,
          frontend_tag_plan: visitor.frontend_tag_plan,
          render_nodes: visitor.render_nodes,
          helper_lowered_elements: visitor.helper_lowered_elements
        )
      rescue StandardError => error
        new(
          path: path,
          parse: {
            ok: false,
            exception: error.class.name,
            message: error.message
          },
          root_shape: {},
          frontend_tag_plan: [],
          render_nodes: [],
          helper_lowered_elements: []
        )
      end

      def self.summary(manifests)
        partials = manifests.select(&:partial?)

        {
          templates_scanned: manifests.size,
          strict_parse_failures: manifests.count { |manifest| !manifest.parse.fetch(:ok) },
          render_nodes: manifests.sum { |manifest| manifest.render_nodes.size },
          helper_lowered_elements: manifests.sum { |manifest| manifest.helper_lowered_elements.size },
          frontend_tag_targets: manifests.sum { |manifest| manifest.frontend_tag_plan.size },
          fragment_root_tags: manifests.sum { |manifest| manifest.frontend_tag_plan.count { |tag| tag.fetch(:kind) == "fragment_root" } },
          render_site_tags: manifests.sum { |manifest| manifest.frontend_tag_plan.count { |tag| tag.fetch(:kind) == "render_site" } },
          partials: partials.size,
          single_root_partials: partials.count { |manifest| manifest.root_shape.fetch(:single_root, false) },
          multi_root_partials: partials.count { |manifest| manifest.root_shape.fetch(:multi_root, false) }
        }
      end

      def self.parse_status(parse_result)
        errors = parse_result.errors.map { |error| error_payload(error) }
        warnings = parse_result.warnings.map { |warning| error_payload(warning) }

        {
          ok: errors.empty?,
          errors: errors,
          warnings: warnings
        }
      end
      private_class_method :parse_status

      def self.error_payload(error)
        {
          class: error.class.name,
          message: error.respond_to?(:message) ? error.message : error.inspect,
          location: error.respond_to?(:location) ? location_payload(error.location) : nil
        }
      end
      private_class_method :error_payload

      def self.location_payload(location)
        return nil unless location

        {
          start: {
            line: location.start.line,
            column: location.start.column
          },
          end: {
            line: location.end.line,
            column: location.end.column
          }
        }
      end
      private_class_method :location_payload

      def initialize(path:, parse:, root_shape:, frontend_tag_plan:, render_nodes:, helper_lowered_elements:)
        @path = path
        @parse = parse
        @root_shape = root_shape
        @frontend_tag_plan = frontend_tag_plan
        @render_nodes = render_nodes
        @helper_lowered_elements = helper_lowered_elements
      end

      def to_h
        {
          path: path,
          parse: parse,
          root_shape: root_shape,
          frontend_tag_plan: frontend_tag_plan,
          render_nodes: render_nodes,
          helper_lowered_elements: helper_lowered_elements
        }
      end

      def partial?
        File.basename(path).start_with?("_")
      end

      class Visitor < ::Herb::Visitor
        attr_reader :frontend_tag_plan, :render_nodes, :helper_lowered_elements

        def initialize(path:, source:)
          super()
          @path = path
          @frontend_tag_plan = []
          @render_nodes = []
          @helper_lowered_elements = []
          @root_shape = nil
          @line_offsets = build_line_offsets(source)
        end

        def root_shape
          @root_shape || EMPTY_ROOT_SHAPE
        end

        def visit_document_node(node)
          significant_children = node.children.reject { |child| insignificant_document_child?(child) }
          root_elements = significant_children.select { |child| html_element?(child) }

          @root_shape = {
            significant_children: significant_children.size,
            root_elements: root_elements.size,
            root_types: significant_children.map { |child| child.class.name },
            single_root: significant_children.size == 1 && root_elements.size == 1,
            multi_root: root_elements.size > 1
          }

          plan_fragment_root_tag(root_elements.first) if partial_template? && root_shape.fetch(:single_root)

          super
        end

        def visit_erb_render_node(node)
          keywords = node.keywords
          render_node = render_node_payload(node, keywords)

          @render_nodes << render_node
          @frontend_tag_plan << render_site_tag(render_node)

          super
        end

        def visit_html_element_node(node)
          if node.respond_to?(:element_source) && node.element_source && node.element_source != "HTML"
            @helper_lowered_elements << {
              location: location_payload(node.location),
              tag_name: token_value(node.tag_name),
              element_source: node.element_source
            }
          end

          super
        end

        private

        attr_reader :path, :line_offsets

        def build_line_offsets(source)
          offsets = [0]
          source.each_line(chomp: false).with_index do |line, index|
            offsets[index + 1] = offsets[index] + line.bytesize
          end
          offsets
        end

        def offset_for(position)
          line_offsets.fetch(position.line - 1) + position.column
        end

        def render_node_payload(node, keywords)
          {
            location: location_payload(node.location),
            site_id: site_id("render", node.location),
            expression: token_value(node.content)&.strip,
            start_offset: offset_for(node.location.start),
            end_offset: offset_for(node.location.end),
            kind: render_kind(keywords),
            partial: token_value(keywords&.partial),
            template_path: token_value(keywords&.template_path),
            layout: token_value(keywords&.layout),
            collection: token_value(keywords&.collection),
            object: token_value(keywords&.object),
            as: token_value(keywords&.as_name),
            locals: Array(keywords&.locals).map { |local| token_value(local.name) },
            block_arguments: Array(node.block_arguments).map { |argument| token_value(argument.name) }
          }
        end

        def plan_fragment_root_tag(root_element)
          @frontend_tag_plan << {
            kind: "fragment_root",
            target: "root_element",
            location: location_payload(root_element.location),
            tag_name: token_value(root_element.tag_name),
            attributes: [
              {
                name: "data-upkeep-frame",
                value: "<%= upkeep_frame_id %>"
              },
              {
                name: "data-upkeep-template",
                value: template_id
              }
            ],
            update_role: "morph or replace this rendered fragment when runtime observations match a committed change"
          }
        end

        def render_site_tag(render_node)
          {
            kind: "render_site",
            target: render_node.fetch(:kind) == "partial" && render_node.fetch(:collection) ? "collection_region" : "opaque_render_output",
            location: render_node.fetch(:location),
            site_id: render_node.fetch(:site_id),
            attributes: [
              {
                name: "data-upkeep-render-site",
                value: render_node.fetch(:site_id)
              }
            ],
            render: {
              kind: render_node.fetch(:kind),
              partial: render_node.fetch(:partial),
              collection: render_node.fetch(:collection),
              object: render_node.fetch(:object),
              as: render_node.fetch(:as)
            },
            update_role: render_site_update_role(render_node)
          }
        end

        def render_site_update_role(render_node)
          if render_node.fetch(:kind) == "partial" && render_node.fetch(:collection)
            "anchor collection membership while child partial roots carry per-record frame tags"
          else
            "record where ActionView runtime must confirm the rendered frame target"
          end
        end

        def render_kind(keywords)
          return "unknown" unless keywords

          %i[
            partial template_path layout file inline_template body plain html
            renderable collection object
          ].find { |name| token_value(keywords.public_send(name)) }&.to_s || "unknown"
        end

        def insignificant_document_child?(node)
          return true if html_text?(node) && token_value(node.content).to_s.strip.empty?
          return true if erb_comment?(node)

          false
        end

        def html_text?(node)
          node.class.name == "Herb::AST::HTMLTextNode"
        end

        def html_element?(node)
          [
            "Herb::AST::HTMLElementNode",
            "Herb::AST::HTMLConditionalElementNode"
          ].include?(node.class.name)
        end

        def erb_comment?(node)
          node.respond_to?(:tag_opening) && token_value(node.tag_opening).to_s.start_with?("<%#")
        end

        def partial_template?
          File.basename(path).start_with?("_")
        end

        def template_id
          Digest::SHA256.hexdigest(path)[0, 16]
        end

        def site_id(kind, location)
          Digest::SHA256.hexdigest([
            path,
            kind,
            location&.start&.line,
            location&.start&.column,
            location&.end&.line,
            location&.end&.column
          ].join(":"))[0, 16]
        end

        def token_value(token)
          return nil unless token
          return token.value if token.respond_to?(:value)

          token.to_s
        end

        def location_payload(location)
          return nil unless location

          {
            start: {
              line: location.start.line,
              column: location.start.column
            },
            end: {
              line: location.end.line,
              column: location.end.column
            }
          }
        end
      end
    end
  end
end
