# frozen_string_literal: true

require_relative "herb/template_manifest"
require_relative "herb/source_instrumenter"

module Upkeep
  module Templates
    Template = Data.define(:name, :source, :kind)

    REGISTRY = {
      "boards/collection" => Template.new("boards/collection", <<~ERB, :page),
        <main>
          <h1><%= h(board.name) %></h1>
          <ul class="cards">
            <%= render partial: "cards/card", collection: cards, as: :card %>
          </ul>
        </main>
      ERB
      "boards/inline" => Template.new("boards/inline", <<~ERB, :page),
        <main>
          <h1><%= h(board.name) %></h1>
          <ul class="cards">
            <% cards.each do |card| %>
              <li id="inline_card_<%= card.id %>"><%= h(card.title) %> / <%= h(card.status) %></li>
            <% end %>
          </ul>
        </main>
      ERB
      "boards/helper_hidden" => Template.new("boards/helper_hidden", <<~ERB, :page),
        <main>
          <h1><%= h(board.name) %></h1>
          <ul class="cards">
            <%= helper_hidden_card_list(cards) %>
          </ul>
        </main>
      ERB
      "boards/preloaded_plain" => Template.new("boards/preloaded_plain", <<~ERB, :page),
        <main>
          <h1><%= h(board.name) %></h1>
          <ul class="cards">
            <% summaries.each do |summary| %>
              <li id="summary_card_<%= summary.id %>"><%= h(summary.title) %></li>
            <% end %>
          </ul>
        </main>
      ERB
      "boards/identity_collection" => Template.new("boards/identity_collection", <<~ERB, :page),
        <main>
          <h1><%= h(board.name) %></h1>
          <ul class="cards">
            <%= render partial: "cards/secure_card", collection: cards, as: :card %>
          </ul>
        </main>
      ERB
      "boards/identity_visible_collection" => Template.new("boards/identity_visible_collection", <<~ERB, :page),
        <main>
          <h1><%= h(board.name) %></h1>
          <ul class="cards">
            <%= render partial: "cards/secure_card", collection: visible_cards(cards), as: :card %>
          </ul>
        </main>
      ERB
      "boards/auth_surfaces" => Template.new("boards/auth_surfaces", <<~ERB, :page),
        <main>
          <h1><%= h(board.name) %></h1>
          <section id="ambient_identity">
            <span class="current-account"><%= h(current_account_id) %></span>
            <span class="current-role"><%= h(current_viewer_role) %></span>
            <span class="session-tenant"><%= h(session_value(:tenant_id)) %></span>
            <span class="cookie-theme"><%= h(cookie_value(:theme)) %></span>
            <span class="request-subdomain"><%= h(request_value(:subdomain)) %></span>
            <span class="warden-user"><%= h(warden_user(:user)&.name) %></span>
          </section>
          <ul class="cards">
            <%= render partial: "cards/secure_card", collection: cards, as: :card %>
          </ul>
        </main>
      ERB
      "cards/_card" => Template.new("cards/_card", <<~ERB, :partial),
        <li class="card" id="card_<%= card.id %>">
          <span class="title"><%= h(CardPresenter.new(card).title) %></span>
          <span class="status"><%= h(card_status_badge(CardPresenter.new(card))) %></span>
        </li>
      ERB
      "cards/_secure_card" => Template.new("cards/_secure_card", <<~ERB, :partial)
        <li class="card" id="secure_card_<%= card.id %>">
          <span class="title"><%= h(SecureCardPresenter.new(card).title) %></span>
          <span class="value"><%= h(card_value_content(SecureCardPresenter.new(card))) %></span>
        </li>
      ERB
    }.freeze

    class Instrumenter
      PARSE_OPTIONS = Upkeep::HerbSupport::TemplateManifest::DEFAULT_PARSE_OPTIONS.merge(
        action_view_helpers: false,
        transform_conditionals: false
      ).freeze

      def initialize
        @instrumented_sources = {}
        @template_plans = {}
      end

      def source_for(template)
        @instrumented_sources[template.name] ||= begin
          Upkeep::HerbSupport::SourceInstrumenter.new(
            manifest: plan_for(template).fetch(:manifest)
          ).instrument(template.source)
        end
      end

      def plan_for(template)
        @template_plans[template.name] ||= begin
          manifest = Upkeep::HerbSupport::TemplateManifest.build(
            path: template.name,
            source: template.source,
            parse_options: PARSE_OPTIONS
          )

          { manifest: manifest, render_sites: render_sites_from(manifest) }
        end
      end

      def render_sites_from(manifest)
        manifest.render_nodes.map do |render_node|
          {
            site_id: render_node.fetch(:site_id),
            expression: render_node.fetch(:expression),
            start_offset: render_node.fetch(:start_offset),
            end_offset: render_node.fetch(:end_offset)
          }
        end
      end

      private :render_sites_from
    end
  end
end
