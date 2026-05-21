# frozen_string_literal: true

require "action_view"
require "action_view/renderer/collection_renderer"
require "active_support/notifications"
require "cgi"
require "digest"
require "stringio"
require_relative "../active_record_query"
require_relative "../herb/manifest_cache"
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

      REQUEST_REPLAY_ENV_KEYS = {
        "host" => "HTTP_HOST",
        "request_method" => "REQUEST_METHOD",
        "user_agent" => "HTTP_USER_AGENT",
        "remote_ip" => "REMOTE_ADDR"
      }.freeze

      RefusedCollection = Data.define(:reason, :message, :suggestions, :error)

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

        Runtime::Observation.capture_frame(frame_id, metadata.merge(recipe: recipe)) do
          with_frame_id(frame_id) { yield }
        end
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
        provenance = Runtime::Observation.relation_provenance_for(collection)
        return provenance if provenance
        return unless active_record_relation?(collection)

        ActiveRecordQuery.analyze(collection)
      rescue ActiveRecordQuery::OpaqueRelationError => error
        handle_refused_collection(error)
      end

      def collection_capture_pair(collection)
        if active_record_relation?(collection)
          rendered_collection = Runtime::RelationObserver.suppress_dependency_tracking { collection.to_a }
          [collection, rendered_collection]
        else
          [collection, collection]
        end
      end

      def template_metadata(template, locals)
        template_static_metadata(template).merge(locals: local_metadata(locals))
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
          replay: (target_kind == "fragment" ? ::Upkeep::Replay::Fragment : ::Upkeep::Replay::Template).new(
            controller_class: controller&.class&.name,
            template: metadata.fetch(:template),
            locals: snapshot_hash(locals)
          )
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
        ambient_inputs = request_ambient_replay_inputs
        env = replay_env(
          controller.request.env,
          path_parameters: controller.request.path_parameters,
          ambient_inputs: ambient_inputs
        )

        ::Upkeep::Replay::Recipe.new(
          kind: :page,
          frame_id: frame_id,
          target_kind: "page",
          target_id: frame_id,
          template: metadata.fetch(:template),
          metadata: metadata,
          runtime: "rails",
          replay: ::Upkeep::Replay::ControllerPage.new(
            controller_class: controller_class.name,
            action: action_name,
            env: serializable_replay_env(
              controller.request.env,
              path_parameters: controller.request.path_parameters,
              ambient_inputs: ambient_inputs
            )
          )
        ) do
          _status, _headers, body = ControllerRuntime.suppress do
            controller_class.action(action_name).call(Replay.rack_env(env))
          end
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
          replay: ::Upkeep::Replay::Collection.new(
            controller_class: controller&.class&.name,
            partial: partial == :derived ? "derived" : partial.to_s,
            collection: snapshot_value(collection, rendered_collection: rendered_collection, relation_analysis: collection_analysis),
            options: snapshot_render_options(options)
          )
        ) do
          replay_options = replay_render_options(options)
          replay_options[:partial] = partial unless partial == :derived
          replay_options[:collection] = replay_collection_value(collection, collection_analysis)
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
        request = controller.request
        {
          class: controller.class.name,
          action: controller.action_name,
          request_method: request.env["REQUEST_METHOD"].to_s,
          path: request.env["PATH_INFO"].to_s,
          query_string_digest: Digest::SHA256.hexdigest(request.env["QUERY_STRING"].to_s)[0, 16],
          path_parameters: request.path_parameters.keys.map(&:to_s).sort
        }
      end

      def serializable_replay_env(env, path_parameters: nil, ambient_inputs: {})
        replay_env(env, path_parameters: path_parameters, ambient_inputs: ambient_inputs).reject do |key, _value|
          key == "rack.input" || key == "rack.errors"
        end
      end

      def replay_env(env, path_parameters: nil, ambient_inputs: {})
        copy = env.each_with_object({}) do |(key, value), replay|
          replay[key] = replay_env_value(value) if replay_env_key?(key)
        end

        session_snapshot = session_replay_snapshot(
          env["rack.session"],
          observed_values: ambient_inputs.fetch(:session, {})
        )
        cookie_header = cookie_replay_header(ambient_inputs.fetch(:cookie, {}))
        copy["rack.session"] = session_snapshot if session_snapshot
        copy["HTTP_COOKIE"] = cookie_header if cookie_header
        request_replay_env(ambient_inputs.fetch(:request, {})).each do |key, value|
          copy[key] = value
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
          value.transform_values { |nested_value| replay_env_scalar_value(nested_value) }
        when Array
          value.map { |nested_value| replay_env_scalar_value(nested_value) }
        else
          replay_env_scalar_value(value)
        end
      end

      def replay_env_scalar_value(value)
        case value
        when Hash
          value.transform_values { |nested_value| replay_env_scalar_value(nested_value) }
        when Array
          value.map { |nested_value| replay_env_scalar_value(nested_value) }
        else
          value
        end
      end

      def request_ambient_replay_inputs
        Runtime::Observation.recorder&.ambient_replay_inputs_for(Runtime::Recorder::REQUEST_NODE_ID) || {}
      end

      def session_replay_snapshot(session, observed_values:)
        values = observed_values.transform_keys(&:to_s)
        return if values.empty?

        session_id = session_id_for_replay(session)
        values = values.merge("session_id" => session_id.to_s) if session_id && !session_id.to_s.empty?

        {
          "__upkeep_replay_type" => "rack_session",
          "values" => replay_env_scalar_value(values)
        }
      end

      def session_id_for_replay(session)
        session.id if session.respond_to?(:id)
      rescue StandardError
        nil
      end

      def cookie_replay_header(observed_values)
        values = observed_values.transform_keys(&:to_s).reject { |_key, value| value.nil? }
        return if values.empty?

        values.map do |key, value|
          "#{CGI.escape(key)}=#{CGI.escape(value.to_s)}"
        end.join("; ")
      end

      def request_replay_env(observed_values)
        observed_values.transform_keys(&:to_s).each_with_object({}) do |(key, value), replay_env|
          env_key = REQUEST_REPLAY_ENV_KEYS[key]
          replay_env[env_key] = replay_env_scalar_value(value) if env_key && !value.nil?
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
        template.instance_variable_set(:@upkeep_herb_original_source, template.source)
        template.instance_variable_set(:@source, instrumented_source)
        template.instance_variable_set(:@upkeep_herb_instrumented, true)
      end

      def erb_template?(template)
        template.identifier.to_s.end_with?(".erb") || template.respond_to?(:handler) && template.handler.class.name.include?("ERB")
      end

      def manifest_for_template(template)
        template.instance_variable_get(:@upkeep_herb_manifest) || begin
          source = template.instance_variable_get(:@upkeep_herb_original_source) || template.source
          manifest = manifest_cache.fetch(
            path: template.virtual_path || template.identifier,
            source: source,
            parse_options: MANIFEST_PARSE_OPTIONS
          )
          template.instance_variable_set(:@upkeep_herb_manifest, manifest)
          manifest
        end
      end

      def template_static_metadata(template)
        template.instance_variable_get(:@upkeep_static_metadata) || begin
          virtual_path = template.virtual_path || template.identifier
          manifest = manifest_for_template(template)
          metadata = {
            kind: partial_template?(template) ? "fragment" : "page",
            template: virtual_path,
            identifier: template.identifier
          }.merge(manifest_metadata(manifest)).freeze
          template.instance_variable_set(:@upkeep_static_metadata, metadata)
          metadata
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

      def manifest_cache
        @manifest_cache ||= HerbSupport::ManifestCache.new
      end

      def reset_manifest_cache!
        @manifest_cache = HerbSupport::ManifestCache.new
      end

      def record_collection_dependency(collection, collection_analysis: nil)
        return if refused_collection_analysis?(collection_analysis)

        analysis = collection_analysis
        analysis ||= ActiveRecordQuery.analyze(collection) if active_record_relation?(collection)
        return unless analysis

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
          snapshot[key.to_s] = key == :locals ? ::Upkeep::Replay::HashValue.new(entries: snapshot_hash(value || {})) : snapshot_value(value)
        end
      end

      def snapshot_value(value, rendered_collection: nil, relation_analysis: nil)
        if value.is_a?(ActiveRecord::Base)
          ::Upkeep::Replay.active_record_value(value)
        elsif active_record_relation?(value)
          if refused_collection_analysis?(relation_analysis)
            return refused_relation_snapshot(value, relation_analysis)
          end

          analysis = relation_analysis || analyze_relation_for_snapshot(value)
          return refused_relation_snapshot(value, analysis) if refused_collection_analysis?(analysis)

          ::Upkeep::Replay::ActiveRecordRelationValue.new(
            model: value.klass.name,
            sql: analysis.sql,
            primary_key: analysis.primary_key,
            appendable: analysis.appendable?,
            limit_value: analysis.limit_value,
            predicates: analysis.predicates,
            member_ids: rendered_collection ? relation_member_ids(analysis.primary_key, rendered_collection) : []
          )
        elsif value.is_a?(Array) && relation_provenance_analysis?(relation_analysis)
          ::Upkeep::Replay::ActiveRecordRelationValue.new(
            model: relation_analysis.model_name,
            sql: relation_analysis.sql,
            primary_key: relation_analysis.primary_key,
            appendable: relation_analysis.appendable?,
            limit_value: relation_analysis.limit_value,
            predicates: relation_analysis.predicates,
            member_ids: rendered_collection ? relation_member_ids(relation_analysis.primary_key, rendered_collection) : []
          )
        elsif value.is_a?(Array)
          ::Upkeep::Replay::ArrayValue.new(items: value.map { |item| snapshot_value(item) })
        elsif value.is_a?(Hash)
          ::Upkeep::Replay::HashValue.new(entries: snapshot_hash(value))
        elsif value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.is_a?(Symbol)
          ::Upkeep::Replay::LiteralValue.new(value: value)
        else
          ::Upkeep::Replay::UnsupportedValue.new(class_name: value.class.name)
        end
      end

      def relation_member_ids(primary_key, rendered_collection)
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

      def handle_refused_collection(error)
        raise error if Upkeep::Rails.configuration.refused_boundary_behavior == :raise

        refused = RefusedCollection.new(
          "opaque_active_record_relation",
          error.message,
          error.suggestions,
          error
        )
        payload = {
          reason: refused.reason,
          message: refused.message,
          suggestions: refused.suggestions,
          source: "active_record_collection"
        }

        if Runtime::Observation.refuse_boundary(payload)
          ActiveSupport::Notifications.instrument("refused_boundary.upkeep", payload)
          warn_refused_boundary(payload)
        end
        refused
      end

      def analyze_relation_for_snapshot(value)
        ActiveRecordQuery.analyze(value)
      rescue ActiveRecordQuery::OpaqueRelationError => error
        handle_refused_collection(error)
      end

      def refused_collection_analysis?(value)
        value.is_a?(RefusedCollection)
      end

      def relation_provenance_analysis?(value)
        value.is_a?(Runtime::RelationProvenance)
      end

      def refused_relation_snapshot(value, refused)
        ::Upkeep::Replay::RefusedActiveRecordRelationValue.new(
          model: value.klass.name,
          sql_digest: Digest::SHA256.hexdigest(value.to_sql)[0, 16],
          reason: refused.reason
        )
      end

      def warn_refused_boundary(payload)
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

        ::Rails.logger.warn(
          "Upkeep refused #{payload.fetch(:source)}: #{payload.fetch(:reason)}. " \
          "#{payload.fetch(:suggestions).join(" ")}"
        )
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

      def replay_collection_value(collection, collection_analysis)
        if collection.is_a?(Array) && relation_provenance_analysis?(collection_analysis)
          return constantize(collection_analysis.model_name).find_by_sql(collection_analysis.sql)
        end

        replay_value(collection)
      end

      def collection_key(collection)
        provenance = Runtime::Observation.relation_provenance_for(collection)
        if provenance
          {
            table: provenance.primary_table,
            predicate_digest: Digest::SHA256.hexdigest(provenance.sql)[0, 16],
            materialized: true
          }
        elsif collection.respond_to?(:klass) && collection.respond_to?(:to_sql)
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

      def constantize(name)
        name.to_s.split("::").reject(&:empty?).reduce(Object) { |scope, const_name| scope.const_get(const_name) }
      end

      def partial_template?(template)
        File.basename(template.virtual_path.to_s).start_with?("_")
      end

      module ViewHelpers
        def upkeep_page_frame_id
          Upkeep::Rails::ActionViewCapture.current_frame_id ||
            raise("upkeep_page_frame_id is only available while rendering an Upkeep page frame")
        end

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
