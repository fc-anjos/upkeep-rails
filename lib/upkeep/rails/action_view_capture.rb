# frozen_string_literal: true

require "action_view"
require "action_view/renderer/collection_renderer"
require "cgi"
require "digest"
require "nokogiri"
require "stringio"
require_relative "../active_record_query"
require_relative "../herb/source_instrumenter"

module Upkeep
  module Rails
    module ActionViewCapture
      module_function

      FRAME_STACK_KEY = :upkeep_rails_frame_stack
      RENDER_SITE_STACK_KEY = :upkeep_rails_render_site_stack

      MANIFEST_PARSE_OPTIONS = HerbSupport::TemplateManifest::DEFAULT_PARSE_OPTIONS.merge(
        action_view_helpers: false,
        transform_conditionals: false
      ).freeze

      REPLAY_HTTP_ENV_KEYS = %w[
        HTTP_ACCEPT
        HTTP_HOST
        HTTP_X_FORWARDED_HOST
        HTTP_X_FORWARDED_PROTO
      ].freeze

      def install
        return if @installed

        ::ActionView::Template.prepend(TemplateHook)
        ::ActionView::CollectionRenderer.prepend(CollectionRendererHook)
        ::ActionView::Base.include(ViewHelpers)

        @installed = true
      end

      def installed?
        !!@installed
      end

      def capture_template(template, view, locals, implicit_locals:, add_to_stack:, block:)
        instrument_template_source!(template)
        captured_locals = locals.dup
        metadata = template_metadata(template, captured_locals)
        controller = controller_for_view(view)
        page_controller = controller if metadata.fetch(:kind) == "page"
        metadata = metadata.merge(controller: controller_metadata(page_controller)) if page_controller
        frame_id = frame_id_for_template(metadata, captured_locals)
        recipe = if page_controller
          controller_page_recipe(frame_id: frame_id, controller: page_controller, metadata: metadata)
        else
          template_recipe(
            frame_id: frame_id,
            template: template,
            view: view,
            controller: controller,
            locals: captured_locals,
            metadata: metadata,
            implicit_locals: implicit_locals,
            add_to_stack: add_to_stack,
            block: block
          )
        end

        html = Runtime::Observation.capture_frame(frame_id, metadata.merge(recipe: recipe)) do
          with_frame_id(frame_id) { yield }
        end

        html && metadata.fetch(:kind) == "page" ? tag_root(html, "data-upkeep-page-frame" => frame_id) : html
      end

      def capture_collection(partial, collection, rendered_collection, context, options, block, collection_analysis: nil)
        captured_options = render_options_for_replay(options)
        metadata = collection_metadata(partial, collection, render_site: current_render_site)
        frame_id = "site:#{metadata.fetch(:site_id)}"
        recipe = collection_recipe(
          frame_id: frame_id,
          partial: partial,
          collection: collection,
          rendered_collection: rendered_collection,
          context: context,
          controller: controller_for_view(context),
          options: captured_options,
          metadata: metadata,
          block: block,
          collection_analysis: collection_analysis
        )

        Runtime::Observation.capture_frame(frame_id, metadata.merge(recipe: recipe)) do
          record_collection_dependency(collection, collection_analysis: collection_analysis)
          yield
        end
      end

      def collection_analysis(collection)
        return unless active_record_relation?(collection)

        ActiveRecordQuery.analyze(collection)
      end

      def collection_capture_pair(collection)
        if active_record_relation?(collection)
          [collection, collection.to_a]
        else
          [collection, collection]
        end
      end

      def template_metadata(template, locals)
        virtual_path = template.virtual_path || template.identifier
        manifest = manifest_for_template(template)
        {
          kind: partial_template?(template) ? "fragment" : "page",
          template: virtual_path,
          identifier: template.identifier,
          locals: local_metadata(locals)
        }.merge(manifest_metadata(manifest))
      end

      def collection_metadata(partial, collection, render_site: nil)
        collection_key = collection_key(collection)
        site_id = render_site&.fetch(:site_id) ||
          Digest::SHA256.hexdigest(["rails_collection", partial.to_s, collection_key].inspect)[0, 16]

        {
          kind: "render_site",
          site_id: site_id,
          partial: partial.to_s,
          collection: collection_key
        }.merge(manifest_metadata(render_site))
      end

      def template_recipe(frame_id:, template:, view:, controller:, locals:, metadata:, implicit_locals:, add_to_stack:, block:)
        target_kind = metadata.fetch(:kind) == "fragment" ? "fragment" : "page"
        ::Upkeep::Replay::Recipe.new(
          kind: metadata.fetch(:kind).to_sym,
          frame_id: frame_id,
          target_kind: target_kind,
          target_id: frame_id,
          template: metadata.fetch(:template),
          metadata: metadata,
          runtime: "rails",
          replay: {
            type: target_kind == "fragment" ? "fragment" : "template",
            controller_class: controller&.class&.name,
            template: metadata.fetch(:template),
            locals: snapshot_hash(locals)
          }.compact
        ) do
          template.render(
            view,
            replay_locals(locals),
            nil,
            implicit_locals: implicit_locals,
            add_to_stack: add_to_stack,
            &block
          )
        end
      end

      def controller_page_recipe(frame_id:, controller:, metadata:)
        controller_class = controller.class
        action_name = controller.action_name
        env = replay_env(controller.request.env, path_parameters: controller.request.path_parameters)

        ::Upkeep::Replay::Recipe.new(
          kind: :page,
          frame_id: frame_id,
          target_kind: "page",
          target_id: frame_id,
          template: metadata.fetch(:template),
          metadata: metadata,
          runtime: "rails",
          replay: {
            type: "controller_page",
            controller_class: controller_class.name,
            action: action_name,
            env: serializable_replay_env(controller.request.env, path_parameters: controller.request.path_parameters)
          }
        ) do
          _status, _headers, body = controller_class.action(action_name).call(replay_env(env))
          collect_response_body(body)
        end
      end

      def collection_recipe(frame_id:, partial:, collection:, rendered_collection:, context:, controller:, options:, metadata:, block:, collection_analysis: nil)
        ::Upkeep::Replay::Recipe.new(
          kind: :render_site,
          frame_id: frame_id,
          target_kind: "render_site",
          target_id: metadata.fetch(:site_id),
          metadata: metadata,
          runtime: "rails",
          replay: {
            type: "collection",
            controller_class: controller&.class&.name,
            partial: partial == :derived ? "derived" : partial.to_s,
            collection: snapshot_value(collection, rendered_collection: rendered_collection, relation_analysis: collection_analysis),
            options: snapshot_render_options(options)
          }.compact
        ) do
          replay_options = replay_render_options(options)
          replay_options[:partial] = partial unless partial == :derived
          replay_options[:collection] = replay_value(collection)
          context.render(replay_options, &block)
        end
      end

      def controller_for_view(view)
        return unless view.respond_to?(:controller)

        controller = view.controller
        return unless controller&.respond_to?(:request) && controller.respond_to?(:action_name)

        controller
      end

      def controller_metadata(controller)
        {
          class: controller.class.name,
          action: controller.action_name,
          request_method: controller.request.request_method,
          path: controller.request.path,
          query_string_digest: Digest::SHA256.hexdigest(controller.request.query_string.to_s)[0, 16],
          path_parameters: controller.request.path_parameters.keys.map(&:to_s).sort
        }
      end

      def serializable_replay_env(env, path_parameters: nil)
        replay_env(env, path_parameters: path_parameters).reject do |key, _value|
          key == "rack.input" || key == "rack.errors"
        end
      end

      def replay_env(env, path_parameters: nil)
        copy = env.each_with_object({}) do |(key, value), replay|
          replay[key] = replay_env_value(value) if replay_env_key?(key)
        end

        copy["rack.input"] = StringIO.new
        copy["rack.errors"] ||= StringIO.new
        copy["action_dispatch.request.path_parameters"] = path_parameters if path_parameters
        copy
      end

      def replay_env_key?(key)
        return false if key == "HTTP_COOKIE"

        REPLAY_HTTP_ENV_KEYS.include?(key) ||
          key.start_with?("REQUEST_") ||
          key.start_with?("SERVER_") ||
          key.start_with?("REMOTE_") ||
          key == "rack.url_scheme" ||
          %w[
            CONTENT_LENGTH
            CONTENT_TYPE
            HTTPS
            PATH_INFO
            QUERY_STRING
            SCRIPT_NAME
            action_dispatch.request.path_parameters
          ].include?(key)
      end

      def replay_env_value(value)
        case value
        when Hash
          value.dup
        when Array
          value.dup
        else
          value
        end
      end

      def collect_response_body(body)
        body.each.to_a.join
      ensure
        body.close if body.respond_to?(:close)
      end

      def instrument_template_source!(template)
        return if template.instance_variable_get(:@upkeep_herb_instrumented)
        return unless erb_template?(template)

        manifest = manifest_for_template(template)
        instrumented_source = HerbSupport::SourceInstrumenter.new(manifest: manifest).instrument(template.source)
        template.instance_variable_set(:@source, instrumented_source)
        template.instance_variable_set(:@upkeep_herb_instrumented, true)
      end

      def erb_template?(template)
        template.identifier.to_s.end_with?(".erb") || template.respond_to?(:handler) && template.handler.class.name.include?("ERB")
      end

      def manifest_for_template(template)
        template.instance_variable_get(:@upkeep_herb_manifest) || begin
          manifest = HerbSupport::TemplateManifest.build(
            path: template.virtual_path || template.identifier,
            source: template.source,
            parse_options: MANIFEST_PARSE_OPTIONS
          )
          template.instance_variable_set(:@upkeep_herb_manifest, manifest)
          manifest
        end
      end

      def manifest_metadata(manifest)
        return {} unless manifest

        path = if manifest.respond_to?(:path)
          manifest.path
        else
          manifest[:manifest_path] || manifest[:path]
        end

        fingerprint = if manifest.respond_to?(:fingerprint)
          manifest.fingerprint
        else
          manifest[:manifest_fingerprint] || manifest[:fingerprint]
        end

        return {} unless path && fingerprint

        {
          manifest_path: path,
          manifest_fingerprint: fingerprint,
          manifest: {
            path: path,
            fingerprint: fingerprint
          }
        }
      end

      def tag_root(html, attributes)
        fragment = Nokogiri::HTML5.fragment(html)
        root = fragment.children.find { |child| child.element? }
        return html unless root

        attributes.each { |name, value| root[name] = value }
        fragment.to_html
      end

      def with_frame_id(frame_id)
        frame_stack.push(frame_id)
        yield
      ensure
        frame_stack.pop
      end

      def current_frame_id
        frame_stack.last
      end

      def frame_stack
        Thread.current[FRAME_STACK_KEY] ||= []
      end

      def with_render_site(render_site)
        render_site_stack.push(render_site)
        yield
      ensure
        render_site_stack.pop
      end

      def current_render_site
        render_site_stack.last
      end

      def render_site_stack
        Thread.current[RENDER_SITE_STACK_KEY] ||= []
      end

      def record_collection_dependency(collection, collection_analysis: nil)
        return unless active_record_relation?(collection)

        analysis = collection_analysis || ActiveRecordQuery.analyze(collection)
        dependency = Dependencies::ActiveRecordCollection.new(
          primary_table: analysis.primary_table,
          table_columns: analysis.table_columns,
          coverage: analysis.coverage,
          sql: analysis.sql,
          predicates: analysis.predicates
        )

        Runtime::Observation.record_dependency(dependency)
      end

      def frame_id_for_template(metadata, locals)
        if metadata.fetch(:kind) == "fragment"
          "fragment:rails:#{metadata.fetch(:template)}:#{locals_identity(locals)}"
        else
          "page:rails:#{metadata.fetch(:template)}"
        end
      end

      def locals_identity(locals)
        record = locals.values.find { |value| value.is_a?(ActiveRecord::Base) }
        return "#{record.class.table_name}:#{record.id}" if record

        Digest::SHA256.hexdigest(local_metadata(locals).inspect)[0, 16]
      end

      def local_metadata(locals)
        locals.transform_values do |value|
          if value.is_a?(ActiveRecord::Base)
            { table: value.class.table_name, id: value.id }
          elsif value.respond_to?(:klass) && value.respond_to?(:to_sql)
            { class: value.class.name, table: value.klass.table_name }
          elsif value.is_a?(Array)
            { class: value.class.name, size: value.size }
          else
            value.class.name
          end
        end
      end

      def render_options_for_replay(options)
        options.each_with_object({}) do |(key, value), replay_options|
          replay_options[key] = key == :locals && value.respond_to?(:dup) ? value.dup : value
        end
      end

      def replay_render_options(options)
        options.each_with_object({}) do |(key, value), replay_options|
          replay_options[key] = key == :locals ? replay_locals(value || {}) : value
        end
      end

      def replay_locals(locals)
        locals.transform_values { |value| replay_value(value) }
      end

      def snapshot_hash(values)
        values.each_with_object({}) do |(key, value), snapshot|
          next if key.to_s.end_with?("_iteration")

          snapshot[key.to_s] = snapshot_value(value)
        end
      end

      def snapshot_render_options(options)
        options.each_with_object({}) do |(key, value), snapshot|
          snapshot[key.to_s] = key == :locals ? { type: "hash", entries: snapshot_hash(value || {}) } : snapshot_value(value)
        end
      end

      def snapshot_value(value, rendered_collection: nil, relation_analysis: nil)
        if value.is_a?(ActiveRecord::Base)
          { type: "active_record", model: value.class.name, id: value.id }
        elsif active_record_relation?(value)
          analysis = relation_analysis || ActiveRecordQuery.analyze(value)
          snapshot = {
            type: "active_record_relation",
            model: value.klass.name,
            sql: analysis.sql,
            primary_key: analysis.primary_key,
            appendable: analysis.appendable?,
            predicates: analysis.predicates
          }
          snapshot[:member_ids] = relation_member_ids(value, rendered_collection) if rendered_collection
          snapshot
        elsif value.is_a?(Array)
          { type: "array", items: value.map { |item| snapshot_value(item) } }
        elsif value.is_a?(Hash)
          { type: "hash", entries: snapshot_hash(value) }
        elsif value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.is_a?(Symbol)
          { type: "literal", value: value }
        else
          { type: "unsupported", class: value.class.name }
        end
      end

      def relation_member_ids(relation, rendered_collection)
        primary_key = relation.klass.primary_key
        return [] unless primary_key

        if rendered_collection.respond_to?(:to_ary)
          return rendered_collection.to_ary.filter_map do |record|
            record.public_send(primary_key).to_s if record.respond_to?(primary_key)
          end
        end

        relation.pluck(primary_key).map(&:to_s)
      end

      def active_record_relation?(value)
        value.respond_to?(:klass) && value.respond_to?(:to_sql)
      end

      def replay_value(value)
        if value.is_a?(ActiveRecord::Base)
          value.class.find(value.id)
        elsif value.respond_to?(:spawn) && value.respond_to?(:klass)
          value.spawn
        elsif value.is_a?(Array)
          value.map { |item| replay_value(item) }
        else
          value
        end
      end

      def collection_key(collection)
        if collection.respond_to?(:klass) && collection.respond_to?(:to_sql)
          {
            table: collection.klass.table_name,
            predicate_digest: Digest::SHA256.hexdigest(collection.to_sql)[0, 16]
          }
        elsif collection.respond_to?(:to_ary)
          { class: collection.class.name, size: collection.to_ary.size }
        else
          { class: collection.class.name }
        end
      end

      def partial_template?(template)
        File.basename(template.virtual_path.to_s).start_with?("_")
      end

      module ViewHelpers
        def upkeep_frame_id
          Upkeep::Rails::ActionViewCapture.current_frame_id ||
            raise("upkeep_frame_id is only available while rendering an Upkeep frame")
        end

        def render_site(site_id, manifest_path: nil, manifest_fingerprint: nil)
          html = Upkeep::Rails::ActionViewCapture.with_render_site(
            {
              site_id: site_id,
              manifest_path: manifest_path,
              manifest_fingerprint: manifest_fingerprint
            }.compact
          ) do
            yield
          end

          %(<upkeep-render-site data-upkeep-render-site="#{CGI.escapeHTML(site_id.to_s)}">#{html}</upkeep-render-site>).html_safe
        end
      end

      module TemplateHook
        def render(view, locals, buffer = nil, implicit_locals: [], add_to_stack: true, &block)
          Upkeep::Rails::ActionViewCapture.capture_template(
            self,
            view,
            locals,
            implicit_locals: implicit_locals,
            add_to_stack: add_to_stack,
            block: block
          ) do
            super
          end
        end
      end

      module CollectionRendererHook
        def render_collection_with_partial(collection, partial, context, block)
          collection_analysis = Upkeep::Rails::ActionViewCapture.collection_analysis(collection)
          source_collection, rendered_collection = Upkeep::Rails::ActionViewCapture.collection_capture_pair(collection)
          Upkeep::Rails::ActionViewCapture.capture_collection(partial, source_collection, rendered_collection, context, @options, block, collection_analysis: collection_analysis) do
            super(rendered_collection, partial, context, block)
          end
        end

        def render_collection_derive_partial(collection, context, block)
          collection_analysis = Upkeep::Rails::ActionViewCapture.collection_analysis(collection)
          source_collection, rendered_collection = Upkeep::Rails::ActionViewCapture.collection_capture_pair(collection)
          Upkeep::Rails::ActionViewCapture.capture_collection(:derived, source_collection, rendered_collection, context, @options, block, collection_analysis: collection_analysis) do
            super(rendered_collection, context, block)
          end
        end
      end
    end
  end
end
