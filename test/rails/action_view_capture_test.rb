# frozen_string_literal: true

require "test_helper"

class RailsCaptureCard < ActiveRecord::Base
  self.table_name = "rails_capture_cards"

  def to_partial_path
    "cards/card"
  end
end

class ActionViewCaptureTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :rails_capture_cards, force: true do |table|
        table.string :title, null: false
        table.string :status, null: false
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def test_rails_resolved_render_shapes_create_frame_graph
    explicit = create_card!("Explicit")
    shorthand = create_card!("Shorthand")
    object = create_card!("Object")

    _html, recorder = capture_render("boards/mixed", {
      explicit_card: explicit,
      shorthand_card: shorthand,
      object_card: object
    })

    frame_report = recorder.graph.report.fetch(:frames)
    fragment_ids = frame_report.filter_map { |frame| frame.fetch(:id) if frame.fetch(:kind) == "fragment" }

    assert_includes fragment_ids, "fragment:rails:cards/_card:rails_capture_cards:#{explicit.id}"
    assert_includes fragment_ids, "fragment:rails:cards/_card:rails_capture_cards:#{shorthand.id}"
    assert_includes fragment_ids, "fragment:rails:cards/_card:rails_capture_cards:#{object.id}"
    assert_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_attribute"
  end

  def test_collection_render_records_render_site_and_selects_membership_change
    create_card!("Plan")
    create_card!("Build")

    _html, recorder = capture_render("boards/collection", cards: RailsCaptureCard.order(:id))

    Upkeep::Runtime::ChangeLog.reset
    create_card!("Review")

    targets = Upkeep::Targeting::Selector.new.select(recorder, Upkeep::Runtime::ChangeLog.events)

    assert_equal ["render_site"], targets.map(&:kind).uniq
    assert_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_collection"
  end

  def test_record_attribute_change_walks_dependency_to_fragment
    card = create_card!("Plan")

    _html, recorder = capture_render("boards/collection", cards: RailsCaptureCard.order(:id))

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    targets = Upkeep::Targeting::Selector.new.select(recorder, Upkeep::Runtime::ChangeLog.events)

    assert_equal [
      ["fragment", "fragment:rails:cards/_card:rails_capture_cards:#{card.id}"]
    ], targets.map { |target| [target.kind, target.id] }
  end

  private

  def create_card!(title)
    RailsCaptureCard.create!(title: title, status: "open")
  end

  def capture_render(template, locals)
    result, recorder = Upkeep::Runtime::Observation.capture_request do
      html = view.render(template: template, locals: locals)
      [html, Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def view
    lookup_context = ActionView::LookupContext.new([resolver])
    ActionView::Base.with_empty_template_cache.new(lookup_context, {}, nil).tap do |view|
      view.prefix_partial_path_with_controller_namespace = false
    end
  end

  def resolver
    ActionView::FixtureResolver.new(
      "boards/mixed.html.erb" => <<~ERB,
        <main>
          <%= render partial: "cards/card", locals: { card: explicit_card } %>
          <%= render "cards/card", card: shorthand_card %>
          <%= render object_card %>
        </main>
      ERB
      "boards/collection.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "cards/card", collection: cards, as: :card %>
          </ul>
        </main>
      ERB
      "cards/_card.html.erb" => <<~ERB
        <li id="card_<%= card.id %>">
          <span class="title"><%= card.title %></span>
          <span class="status"><%= card.status %></span>
        </li>
      ERB
    )
  end
end
