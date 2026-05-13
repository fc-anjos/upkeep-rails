# frozen_string_literal: true

require "test_helper"

class HerbDeveloperReportTest < Minitest::Test
  def test_reports_template_blockers_and_page_fallback_actions
    report = Upkeep::HerbSupport::DeveloperReport.new(
      manifests: manifests,
      proof_report: proof_report
    ).to_h

    inline = report.fetch(:templates).find { |template| template.fetch(:path) == "boards/inline" }
    helper = report.fetch(:templates).find { |template| template.fetch(:path) == "boards/helper_hidden" }
    partial = report.fetch(:templates).find { |template| template.fetch(:path) == "cards/_card" }

    assert report.fetch(:summary).fetch(:gate_passed)
    assert_equal({ "no_herb_render_site" => 1, "helper_hidden_collection" => 1 }, report.fetch(:summary).fetch(:page_fallback_reasons))
    assert_includes inline.fetch(:blockers), "page_without_render_site"
    assert_includes helper.fetch(:blockers), "page_without_render_site"
    assert_empty partial.fetch(:blockers)

    actions = report.fetch(:actions)
    assert_action(actions, source: "template", path: "boards/inline", reason: "page_without_render_site")
    assert_action(actions, source: "proof", target: "page:boards/helper_hidden", reason: "helper_hidden_collection")
  end

  private

  def manifests
    Upkeep::HerbSupport::RuntimeAlignment.build_manifests([
      Upkeep::Templates::Template.new("boards/inline", "<main><% cards.each do |card| %><span><%= card.title %></span><% end %></main>", :page),
      Upkeep::Templates::Template.new("boards/helper_hidden", "<main><%= helper_hidden_card_list(cards) %></main>", :page),
      Upkeep::Templates::Template.new("boards/collection", '<main><%= render partial: "cards/card", collection: cards, as: :card %></main>', :page),
      Upkeep::Templates::Template.new("cards/_card", "<li><%= card.title %></li>", :partial)
    ])
  end

  def proof_report
    {
      summary: {
        page_fallback_reasons: {
          "no_herb_render_site" => 1,
          "helper_hidden_collection" => 1
        }
      },
      cases: [
        {
          name: "inline",
          selected_targets: [
            { kind: "page", id: "page:boards/inline", fallback_reason: "no_herb_render_site" }
          ]
        },
        {
          name: "helper",
          selected_targets: [
            { kind: "page", id: "page:boards/helper_hidden", fallback_reason: "helper_hidden_collection" }
          ]
        }
      ]
    }
  end

  def assert_action(actions, expected)
    assert actions.any? { |action| expected.all? { |key, value| action[key] == value } }, "expected action #{expected.inspect}"
  end
end
