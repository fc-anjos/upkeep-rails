# frozen_string_literal: true

require "cgi"
require "digest"
require "erb"
require "nokogiri"

module Upkeep
  module Rendering
    RenderResult = Data.define(:html, :recorder)

    class Engine
      def initialize
        @instrumenter = Templates::Instrumenter.new
      end

      def render_request(template_name, request_builder, user: nil)
        html = nil
        result, recorder = Runtime::Observation.capture_request do
          Runtime::Current.set(user: user) do
            assigns = request_builder.call
            page_frame_id = page_frame_id(template_name)
            context = TemplateContext.new(self)

            html = Runtime::Observation.capture_frame(page_frame_id, kind: "page", template: template_name) do
              context.render_template(template_name, assigns)
            end

            html = tag_root(html, "data-upkeep-page-frame" => page_frame_id)
            RenderResult.new(html, Runtime::Observation.recorder)
          end
        end

        result || RenderResult.new(html, recorder)
      end

      def render_template(template_name, locals, context)
        template = Templates::REGISTRY.fetch(template_name)
        source = @instrumenter.source_for(template)
        render_erb(source, locals, context)
      end

      def render_partial(template_name, locals, context)
        frame_id = fragment_frame_id(template_name, locals)

        html = Runtime::Observation.capture_frame(frame_id, kind: "fragment", template: template_name, locals: frame_local_metadata(locals)) do
          render_template(template_name, locals, context)
        end

        tag_root(html, "data-upkeep-frame" => frame_id, "data-upkeep-template" => template_digest(template_name))
      end

      private

      def render_erb(source, locals, context)
        context_binding = context.template_binding
        locals.each { |name, value| context_binding.local_variable_set(name.to_sym, value) }
        ERB.new(source, trim_mode: "-").result(context_binding)
      end

      def tag_root(html, attributes)
        fragment = Nokogiri::HTML5.fragment(html)
        root = fragment.children.find { |child| child.element? }
        raise "rendered template has no root element" unless root

        attributes.each { |name, value| root[name] = value }
        fragment.to_html
      end

      def page_frame_id(template_name)
        "page:#{template_name}"
      end

      def fragment_frame_id(template_name, locals)
        record_pair = locals.find { |_name, value| value.is_a?(ActiveRecord::Base) }
        if record_pair
          _name, record = record_pair
          "fragment:#{template_name}:#{record.class.table_name}:#{record.id}"
        else
          "fragment:#{template_name}:#{Digest::SHA256.hexdigest(locals.inspect)[0, 16]}"
        end
      end

      def frame_local_metadata(locals)
        locals.transform_values do |value|
          if value.is_a?(ActiveRecord::Base)
            { table: value.class.table_name, id: value.id }
          else
            value.class.name
          end
        end
      end

      def template_digest(template_name)
        Digest::SHA256.hexdigest(template_name)[0, 16]
      end
    end

    class TemplateContext
      CardPresenter = Domain::CardPresenter
      SecureCardPresenter = Domain::SecureCardPresenter

      def initialize(engine)
        @engine = engine
      end

      def render_template(template_name, locals)
        @engine.render_template(template_name, locals, self)
      end

      def render_site(site_id)
        html = Runtime::Observation.capture_frame("site:#{site_id}", kind: "render_site", site_id: site_id) do
          yield
        end

        %(<upkeep-render-site data-upkeep-render-site="#{h(site_id)}">#{html}</upkeep-render-site>)
      end

      def render(partial:, collection: nil, as: nil, locals: {})
        if collection
          record_collection_dependency(collection)
          collection.map { |record| render(partial: partial, locals: locals.merge((as || inferred_local_name(partial)).to_sym => record)) }.join
        else
          @engine.render_partial(partial_name(partial), locals, self)
        end
      end

      def helper_hidden_card_list(cards)
        render(partial: "cards/card", collection: cards, as: :card)
      end

      def visible_cards(cards)
        cards.select { |card| Runtime::Current.user.can_see_card_value?(card) }
      end

      def card_status_badge(presenter)
        presenter.status_label
      end

      def card_value_content(presenter)
        presenter.value_content
      end

      def h(value)
        CGI.escapeHTML(value.to_s)
      end

      def template_binding
        binding
      end

      private

      def record_collection_dependency(collection)
        return unless collection.respond_to?(:klass) && collection.respond_to?(:to_sql)

        sql = collection.to_sql
        columns = (Runtime::Observation.columns_from_sql(sql) + [collection.klass.primary_key]).compact.uniq.sort
        dependency = Dependencies::ActiveRecordCollection.new(
          table: collection.klass.table_name,
          sql: sql,
          columns: columns
        )

        Runtime::Observation.record_dependency(dependency, event: {
          type: "collection_dependency",
          table: collection.klass.table_name,
          sql: sql,
          columns: columns
        })
      end

      def partial_name(partial)
        parts = partial.split("/")
        parts[-1] = "_#{parts[-1]}" unless parts[-1].start_with?("_")
        parts.join("/")
      end

      def inferred_local_name(partial)
        partial.split("/").last.delete_prefix("_")
      end
    end
  end
end
