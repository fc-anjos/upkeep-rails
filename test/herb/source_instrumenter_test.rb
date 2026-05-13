# frozen_string_literal: true

require "erb"
require "test_helper"

class HerbSourceInstrumenterTest < Minitest::Test
  Card = Data.define(:title)

  def test_inserts_fragment_root_markers_in_source
    source = '<li class="card"><%= card.title %></li>'
    manifest = build_manifest(path: "cards/_card", source: source)

    instrumented = instrument(manifest, source)
    html = render_erb(instrumented, FragmentContext.new(frame_id: "fragment:cards/_card:cards:1"))

    assert_includes html, 'data-upkeep-frame="fragment:cards/_card:cards:1"'
    assert_includes html, %(data-upkeep-template="#{template_id(manifest)}")
    assert_equal '<li class="card">Plan</li>', strip_upkeep_attributes(html)
  end

  def test_wraps_render_sites_using_manifest_offsets
    source = '<main><%= render partial: "cards/card", collection: cards, as: :card %></main>'
    manifest = build_manifest(path: "boards/show", source: source)
    render_site_id = manifest.render_nodes.first.fetch(:site_id)

    context = RenderSiteContext.new
    html = render_erb(instrument(manifest, source), context)

    assert_equal [render_site_id], context.render_site_ids
    assert_includes html, %(<upkeep-render-site data-upkeep-render-site="#{render_site_id}"><li>Plan</li></upkeep-render-site>)
  end

  def test_does_not_duplicate_existing_fragment_root_markers
    source = '<li data-upkeep-frame="<%= upkeep_frame_id %>" data-upkeep-template="static"><%= card.title %></li>'
    manifest = build_manifest(path: "cards/_card", source: source)

    instrumented = instrument(manifest, source)

    assert_equal 1, instrumented.scan("data-upkeep-frame").size
    assert_equal 1, instrumented.scan("data-upkeep-template").size
  end

  private

  def build_manifest(path:, source:)
    Upkeep::HerbSupport::TemplateManifest.build(path: path, source: source)
  end

  def instrument(manifest, source)
    Upkeep::HerbSupport::SourceInstrumenter.new(manifest: manifest).instrument(source)
  end

  def render_erb(source, context)
    ERB.new(source, trim_mode: "-").result(context.instance_eval { binding })
  end

  def template_id(manifest)
    manifest.frontend_tag_plan.first.fetch(:attributes).find { |attribute| attribute.fetch(:name) == "data-upkeep-template" }.fetch(:value)
  end

  def strip_upkeep_attributes(html)
    html
      .gsub(/\sdata-upkeep-frame="[^"]+"/, "")
      .gsub(/\sdata-upkeep-template="[^"]+"/, "")
  end

  class FragmentContext
    attr_reader :card

    def initialize(frame_id:)
      @frame_id = frame_id
      @card = Card.new("Plan")
    end

    def upkeep_frame_id
      @frame_id
    end
  end

  class RenderSiteContext
    attr_reader :render_site_ids

    def initialize
      @render_site_ids = []
    end

    def cards
      [Card.new("Plan")]
    end

    def render(partial:, collection:, as:)
      collection.map { |card| "<li>#{card.title}</li>" }.join
    end

    def render_site(site_id)
      render_site_ids << site_id
      %(<upkeep-render-site data-upkeep-render-site="#{site_id}">#{yield}</upkeep-render-site>)
    end
  end
end
