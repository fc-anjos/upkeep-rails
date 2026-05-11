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

      def capture_template(template, locals)
        metadata = template_metadata(template, locals)
        Runtime::Observation.capture_frame(frame_id_for_template(metadata, locals), metadata) { yield }
      end

      def capture_collection(partial, collection)
        metadata = collection_metadata(partial, collection)

        Runtime::Observation.capture_frame("site:#{metadata.fetch(:site_id)}", metadata) do
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
          Upkeep::Rails::ActionViewCapture.capture_template(self, locals) do
            super
          end
        end
      end

      module CollectionRendererHook
        def render_collection_with_partial(collection, partial, context, block)
          Upkeep::Rails::ActionViewCapture.capture_collection(partial, collection) do
            super
          end
        end

        def render_collection_derive_partial(collection, context, block)
          Upkeep::Rails::ActionViewCapture.capture_collection(:derived, collection) do
            super
          end
        end
      end
    end
  end
end
