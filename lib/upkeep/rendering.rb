# frozen_string_literal: true

require "cgi"
require "digest"
require "erb"
require "nokogiri"
require_relative "active_record_query"

module Upkeep
  module Rendering
    RenderResult = Data.define(:html, :recorder)

    class Engine
      def initialize
        @instrumenter = Templates::Instrumenter.new
      end

      def render_request(template_name, request_builder, user: nil, session: {}, cookies: {}, request: {}, warden: nil, current_attributes: {})
        html = nil
        result, recorder = Runtime::Observation.capture_request do
          Runtime::Current.set(user: user) do
            with_current_attributes(current_attributes) do
              assigns = request_builder.call
              page_frame_id = page_frame_id(template_name)
              recipe = Replay::Recipe.new(
                kind: :page,
                frame_id: page_frame_id,
                target_kind: "page",
                target_id: page_frame_id,
                template: template_name,
                metadata: { user: replay_value_metadata(user) }
              ) do
                render_request(
                  template_name,
                  request_builder,
                  user: reload_value(user),
                  session: session,
                  cookies: cookies,
                  request: request,
                  warden: replay_warden(warden),
                  current_attributes: current_attributes
                ).html
              end
              context = TemplateContext.new(self, session: session, cookies: cookies, request: request, warden: warden, page_recipe: recipe)

              html = Runtime::Observation.capture_frame(
                page_frame_id,
                manifest_metadata(template_name).merge(kind: "page", template: template_name, recipe: recipe)
              ) do
                context.render_template(template_name, assigns)
              end

              html = tag_root(html, "data-upkeep-page-frame" => page_frame_id)
              RenderResult.new(html, Runtime::Observation.recorder)
            end
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
        recipe = Replay::Recipe.new(
          kind: :fragment,
          frame_id: frame_id,
          target_kind: "fragment",
          target_id: frame_id,
          template: template_name,
          metadata: { locals: frame_local_metadata(locals) }
        ) do
          if context.page_recipe
            target = Targeting::Target.new("fragment", frame_id, "fragment replay")
            Targeting::Extraction.extract_target_html(context.page_recipe.render, target)
          else
            render_partial(template_name, replay_locals(locals), context)
          end
        end

        html = Runtime::Observation.capture_frame(
          frame_id,
          manifest_metadata(template_name).merge(kind: "fragment", template: template_name, locals: frame_local_metadata(locals), recipe: recipe)
        ) do
          context.with_upkeep_frame(frame_id) do
            render_template(template_name, locals, context)
          end
        end

        html
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

      def manifest_metadata(template_name)
        template = Templates::REGISTRY.fetch(template_name)
        manifest = @instrumenter.manifest_for(template)

        {
          manifest_path: manifest.path,
          manifest_fingerprint: manifest.fingerprint
        }
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

      def with_current_attributes(attributes)
        if defined?(Domain::CurrentContext)
          Domain::CurrentContext.set(attributes) { yield }
        else
          yield
        end
      end

      def replay_locals(locals)
        locals.transform_values { |value| reload_value(value) }
      end

      def reload_value(value)
        if value.is_a?(ActiveRecord::Base)
          value.class.find(value.id)
        else
          value
        end
      end

      def replay_warden(value)
        case value
        when Hash
          value.transform_values { |user| reload_value(user) }
        else
          value
        end
      end

      def replay_value_metadata(value)
        if value.is_a?(ActiveRecord::Base)
          { table: value.class.table_name, id: value.id }
        elsif value
          { class: value.class.name }
        end
      end
    end

    class TemplateContext
      CardPresenter = Domain::CardPresenter
      SecureCardPresenter = Domain::SecureCardPresenter

      attr_reader :page_recipe

      def initialize(engine, session: {}, cookies: {}, request: {}, warden: nil, page_recipe: nil)
        @engine = engine
        @session = Runtime::ObservedHash.new(source: :session, values: session)
        @cookies = Runtime::ObservedHash.new(source: :cookie, values: cookies)
        @request = request.respond_to?(:env) ? request : Runtime::ObservedRequest.new(request)
        @warden = warden.respond_to?(:user) ? warden : Runtime::ObservedWarden.new(warden || {})
        @page_recipe = page_recipe
      end

      def render_template(template_name, locals)
        @engine.render_template(template_name, locals, self)
      end

      def with_upkeep_frame(frame_id)
        previous_frame_id = @upkeep_frame_id
        @upkeep_frame_id = frame_id
        yield
      ensure
        @upkeep_frame_id = previous_frame_id
      end

      def upkeep_frame_id
        @upkeep_frame_id || raise("upkeep_frame_id is only available while rendering a fragment")
      end

      def render_site(site_id, manifest_path: nil, manifest_fingerprint: nil)
        frame_id = "site:#{site_id}"
        metadata = {
          kind: "render_site",
          site_id: site_id,
          manifest_path: manifest_path,
          manifest_fingerprint: manifest_fingerprint
        }.compact
        recipe = Replay::Recipe.new(
          kind: :render_site,
          frame_id: frame_id,
          target_kind: "render_site",
          target_id: site_id,
          metadata: { site_id: site_id }
        ) do
          if page_recipe
            target = Targeting::Target.new("render_site", site_id, "render-site replay")
            Targeting::Extraction.extract_target_html(page_recipe.render, target)
          else
            html = Runtime::Observation.capture_frame(frame_id, metadata) do
              yield
            end

            %(<upkeep-render-site data-upkeep-render-site="#{h(site_id)}">#{html}</upkeep-render-site>)
          end
        end

        html = Runtime::Observation.capture_frame(frame_id, metadata.merge(recipe: recipe)) do
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

      def current_account_id
        Domain::CurrentContext.account_id
      end

      def current_viewer_role
        Domain::CurrentContext.viewer_role
      end

      def session_value(key)
        @session[key]
      end

      def cookie_value(key)
        @cookies[key]
      end

      def request_value(key)
        @request.public_send(key)
      end

      def warden_user(scope = :user)
        @warden.user(scope)
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

        analysis = ActiveRecordQuery.analyze(collection)
        dependency = Dependencies::ActiveRecordCollection.new(
          primary_table: analysis.primary_table,
          table_columns: analysis.table_columns,
          coverage: analysis.coverage,
          sql: analysis.sql,
          predicates: analysis.predicates
        )

        Runtime::Observation.record_dependency(dependency)
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
