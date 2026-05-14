# frozen_string_literal: true

require "test_helper"

class HerbTemplateManifestTest < Minitest::Test
  def test_single_root_partial_gets_fragment_root_tag
    manifest = build_manifest(
      path: "app/views/cards/_card.html.erb",
      source: <<~ERB
        <li class="card">
          <%= card.title %>
        </li>
      ERB
    )

    assert manifest.parse.fetch(:ok)
    assert manifest.root_shape.fetch(:single_root)
    assert_equal ["fragment_root"], manifest.frontend_tag_plan.map { |tag| tag.fetch(:kind) }

    tag = manifest.frontend_tag_plan.first
    assert_equal "li", tag.fetch(:tag_name)
    assert_equal ["data-upkeep-frame", "data-upkeep-template"], tag.fetch(:attributes).map { |attribute| attribute.fetch(:name) }
  end

  def test_collection_render_gets_stable_render_site_tag
    manifest = build_manifest(
      path: "app/views/boards/show.html.erb",
      source: <<~ERB
        <main>
          <%= render partial: "cards/card", collection: @cards, as: :card %>
        </main>
      ERB
    )

    assert manifest.parse.fetch(:ok)
    assert_equal 1, manifest.render_nodes.size
    assert_equal 2, manifest.frontend_tag_plan.size

    render_node = manifest.render_nodes.first
    tag = manifest.frontend_tag_plan.find { |entry| entry.fetch(:kind) == "render_site" }

    assert_equal "partial", render_node.fetch(:kind)
    assert_equal "cards/card", render_node.fetch(:partial)
    assert_equal "@cards", render_node.fetch(:collection)
    assert_equal "card", render_node.fetch(:as)
    assert_operator render_node.fetch(:start_offset), :<, render_node.fetch(:end_offset)
    assert_equal render_node.fetch(:site_id), tag.fetch(:site_id)
    assert_equal "collection_region", tag.fetch(:target)
    assert_match(/\A[0-9a-f]{16}\z/, render_node.fetch(:site_id))
  end

  def test_html_doctype_does_not_prevent_page_root_tag
    manifest = build_manifest(
      path: "app/views/layouts/application.html.erb",
      source: <<~ERB
        <!doctype html>
        <html>
          <body>Launch</body>
        </html>
      ERB
    )

    assert manifest.parse.fetch(:ok)
    assert manifest.root_shape.fetch(:single_root)
    assert_equal ["page_root"], manifest.frontend_tag_plan.map { |tag| tag.fetch(:kind) }
    assert_equal "html", manifest.frontend_tag_plan.first.fetch(:tag_name)
  end

  def test_summary_reports_phase_one_gate_metrics
    manifests = [
      build_manifest(path: "app/views/cards/_card.html.erb", source: "<li><%= card.title %></li>"),
      build_manifest(path: "app/views/boards/show.html.erb", source: '<main><%= render partial: "cards/card", collection: @cards, as: :card %></main>')
    ]

    summary = Upkeep::HerbSupport::TemplateManifest.summary(manifests)

    assert_equal 2, summary.fetch(:templates_scanned)
    assert_equal 0, summary.fetch(:strict_parse_failures)
    assert_equal 1, summary.fetch(:render_nodes)
    assert_equal 3, summary.fetch(:frontend_tag_targets)
    assert_equal 1, summary.fetch(:page_root_tags)
    assert_equal 1, summary.fetch(:fragment_root_tags)
    assert_equal 1, summary.fetch(:render_site_tags)
    assert_equal 1, summary.fetch(:single_root_partials)
  end

  def test_parse_errors_are_captured_in_manifest
    manifest = build_manifest(
      path: "app/views/cards/_broken.html.erb",
      source: "<div><span></div>"
    )

    refute manifest.parse.fetch(:ok)
    assert_empty manifest.frontend_tag_plan
    assert_empty manifest.render_nodes
  end

  private

  def build_manifest(path:, source:)
    Upkeep::HerbSupport::TemplateManifest.build(path: path, source: source)
  end
end
