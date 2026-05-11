# frozen_string_literal: true

require "action_view"
require "action_view/renderer/collection_renderer"
require "digest"
require "stringio"

module Upkeep
  module Rails
    module ActionViewCapture
      module_function

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

        @installed = true
      end

      def installed?
        !!@installed
      end

      def capture_template(template, view, locals, implicit_locals:, add_to_stack:, block:)
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

        Runtime::Observation.capture_frame(frame_id, metadata.merge(recipe: recipe)) { yield }
      end

      def capture_collection(partial, collection, context, options, block)
        captured_options = render_options_for_replay(options)
        metadata = collection_metadata(partial, collection)
        frame_id = "site:#{metadata.fetch(:site_id)}"
        recipe = collection_recipe(
          frame_id: frame_id,
          partial: partial,
          collection: collection,
          context: context,
          controller: controller_for_view(context),
          options: captured_options,
          metadata: metadata,
          block: block
        )

        Runtime::Observation.capture_frame(frame_id, metadata.merge(recipe: recipe)) do
          record_collection_dependency(collection)
          yield
        end
      end

      def template_metadata(template, locals)
        virtual_path = template.virtual_path || template.identifier
        {
          kind: partial_template?(template) ? "fragment" : "page",
          template: virtual_path,
          identifier: template.identifier,
          locals: local_metadata(locals)
        }
      end

      def collection_metadata(partial, collection)
        collection_key = collection_key(collection)
        site_id = Digest::SHA256.hexdigest(["rails_collection", partial.to_s, collection_key].inspect)[0, 16]

        {
          kind: "render_site",
          site_id: site_id,
          partial: partial.to_s,
          collection: collection_key
        }
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

      def collection_recipe(frame_id:, partial:, collection:, context:, controller:, options:, metadata:, block:)
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
            collection: snapshot_value(collection),
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

      def record_collection_dependency(collection)
        return unless collection.respond_to?(:klass) && collection.respond_to?(:to_sql)

        sql = collection.to_sql
        columns = (Runtime::Observation.columns_from_sql(sql) + [collection.klass.primary_key]).compact.uniq.sort
        dependency = Dependencies::ActiveRecordCollection.new(
          table: collection.klass.table_name,
          sql: sql,
          columns: columns
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

      def snapshot_value(value)
        if value.is_a?(ActiveRecord::Base)
          { type: "active_record", model: value.class.name, id: value.id }
        elsif value.respond_to?(:klass) && value.respond_to?(:to_sql)
          {
            type: "active_record_relation",
            model: value.klass.name,
            sql: value.to_sql,
            primary_key: value.klass.primary_key,
            member_ids: relation_member_ids(value)
          }
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

      def relation_member_ids(relation)
        primary_key = relation.klass.primary_key
        return [] unless primary_key

        relation.pluck(primary_key).map(&:to_s)
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
          Upkeep::Rails::ActionViewCapture.capture_collection(partial, collection, context, @options, block) do
            super
          end
        end

        def render_collection_derive_partial(collection, context, block)
          Upkeep::Rails::ActionViewCapture.capture_collection(:derived, collection, context, @options, block) do
            super
          end
        end
      end
    end
  end
end
