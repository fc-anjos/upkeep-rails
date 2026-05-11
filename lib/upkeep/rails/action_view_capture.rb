# frozen_string_literal: true

require "action_view"
require "action_view/renderer/collection_renderer"
require "digest"

module Upkeep
  module Rails
    module ActionViewCapture
      module_function

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
        frame_id = frame_id_for_template(metadata, captured_locals)
        recipe = template_recipe(
          frame_id: frame_id,
          template: template,
          view: view,
          locals: captured_locals,
          metadata: metadata,
          implicit_locals: implicit_locals,
          add_to_stack: add_to_stack,
          block: block
        )

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

      def template_recipe(frame_id:, template:, view:, locals:, metadata:, implicit_locals:, add_to_stack:, block:)
        target_kind = metadata.fetch(:kind) == "fragment" ? "fragment" : "page"
        Replay::Recipe.new(
          kind: metadata.fetch(:kind).to_sym,
          frame_id: frame_id,
          target_kind: target_kind,
          target_id: frame_id,
          template: metadata.fetch(:template),
          metadata: metadata
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

      def collection_recipe(frame_id:, partial:, collection:, context:, options:, metadata:, block:)
        Replay::Recipe.new(
          kind: :render_site,
          frame_id: frame_id,
          target_kind: "render_site",
          target_id: metadata.fetch(:site_id),
          metadata: metadata
        ) do
          replay_options = replay_render_options(options)
          replay_options[:partial] = partial unless partial == :derived
          replay_options[:collection] = replay_value(collection)
          context.render(replay_options, &block)
        end
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
