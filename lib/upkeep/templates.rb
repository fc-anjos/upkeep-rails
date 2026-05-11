# frozen_string_literal: true

require "digest"
require_relative "herb_loader"

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
      def initialize
        @instrumented_sources = {}
        @template_plans = {}
      end

      def source_for(template)
        @instrumented_sources[template.name] ||= begin
          source = template.source.dup
          plan_for(template).fetch(:render_sites).sort_by { |site| -site.fetch(:start_offset) }.each do |site|
            source[site.fetch(:start_offset)...site.fetch(:end_offset)] =
              %(<%= render_site("#{site.fetch(:site_id)}") { #{site.fetch(:expression)} } %>)
          end
          source
        end
      end

      def plan_for(template)
        @template_plans[template.name] ||= begin
          parse = Herb.parse(template.source, strict: true, render_nodes: true, track_whitespace: true)
          visitor = RenderSiteVisitor.new(template.name, template.source)
          parse.value&.accept(visitor)
          { render_sites: visitor.render_sites }
        end
      end
    end

    class RenderSiteVisitor < Herb::Visitor
      attr_reader :render_sites

      def initialize(template_name, source)
        super()
        @template_name = template_name
        @render_sites = []
        @line_offsets = build_line_offsets(source)
      end

      def visit_erb_render_node(node)
        @render_sites << {
          site_id: site_id(node.location),
          expression: node.content.value.strip,
          start_offset: offset_for(node.location.start),
          end_offset: offset_for(node.location.end)
        }

        super
      end

      private

      attr_reader :template_name, :line_offsets

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

      def site_id(location)
        Digest::SHA256.hexdigest([
          template_name,
          location.start.line,
          location.start.column,
          location.end.line,
          location.end.column
        ].join(":"))[0, 16]
      end
    end
  end
end
