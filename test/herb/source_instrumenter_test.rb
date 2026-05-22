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

  def test_marks_render_site_container_using_manifest_offsets
    source = '<main><ul><%= render partial: "cards/card", collection: cards, as: :card %></ul></main>'
    manifest = build_manifest(path: "boards/show", source: source)
    render_site_id = manifest.render_nodes.first.fetch(:site_id)

    context = RenderSiteContext.new
    html = render_erb(instrument(manifest, source), context)

    assert_equal [render_site_id], context.render_site_ids
    assert_equal [manifest.path], context.manifest_paths
    assert_equal [manifest.fingerprint], context.manifest_fingerprints
    assert_equal %(<main data-upkeep-page-frame="page:boards/show"><ul data-upkeep-render-site="#{render_site_id}"><li>Plan</li></ul></main>), html
  end

  def test_marks_render_object_shorthand_as_runtime_confirmed_render_site_candidate
    source = '<main><ul><%= render cards %></ul></main>'
    manifest = build_manifest(path: "boards/show", source: source)
    render_site_id = manifest.render_nodes.first.fetch(:site_id)

    context = RenderSiteContext.new
    html = render_erb(instrument(manifest, source), context)

    assert_equal [render_site_id], context.render_site_ids
    assert_equal %(<main data-upkeep-page-frame="page:boards/show"><ul data-upkeep-render-site="#{render_site_id}"><li>Plan</li></ul></main>), html
  end

  def test_marks_tag_helper_render_site_container_through_helper_arguments
    source = '<main><%= tag.ul id: "cards" do %><%= render partial: "cards/card", collection: cards, as: :card %><% end %></main>'
    manifest = build_manifest(path: "boards/show", source: source)
    render_site_id = manifest.render_nodes.first.fetch(:site_id)

    instrumented = instrument(manifest, source)

    assert_includes instrumented, %{tag.ul id: "cards", "data-upkeep-render-site" => "#{render_site_id}" do}
    assert_includes instrumented, %{upkeep_frame("#{render_site_id}"}
  end

  def test_marks_content_tag_render_site_container_through_helper_arguments
    source = '<main><%= content_tag :ul, class: "cards" do %><%= render partial: "cards/card", collection: cards, as: :card %><% end %></main>'
    manifest = build_manifest(path: "boards/show", source: source)
    render_site_id = manifest.render_nodes.first.fetch(:site_id)

    instrumented = instrument(manifest, source)

    assert_includes instrumented, %{content_tag :ul, class: "cards", "data-upkeep-render-site" => "#{render_site_id}" do}
    assert_includes instrumented, %{upkeep_frame("#{render_site_id}"}
  end

  def test_does_not_create_render_site_when_collection_has_static_siblings
    source = '<main><ul><li>Header</li><%= render partial: "cards/card", collection: cards, as: :card %></ul></main>'
    manifest = build_manifest(path: "boards/show", source: source)

    context = RenderSiteContext.new
    html = render_erb(instrument(manifest, source), context)

    assert_empty context.render_site_ids
    assert_equal '<main data-upkeep-page-frame="page:boards/show"><ul><li>Header</li><li>Plan</li></ul></main>', html
  end

  def test_recovered_parse_adds_broad_root_marker_without_trusting_render_sites
    source = '<main><ul><li><%= render partial: "cards/card", collection: cards, as: :card %></ul></main>'
    manifest = build_manifest(path: "boards/recovered", source: source)

    instrumented = instrument(manifest, source)

    refute manifest.parse.fetch(:ok)
    assert manifest.recovered?
    assert_includes instrumented, 'data-upkeep-page-frame="<%= upkeep_page_frame_id %>"'
    refute_includes instrumented, "upkeep_frame("
    refute_includes instrumented, "data-upkeep-render-site"
  end

  def test_inserts_page_root_marker_in_source
    source = "<main><h1>Launch</h1></main>"
    manifest = build_manifest(path: "boards/show", source: source)

    html = render_erb(instrument(manifest, source), PageContext.new(frame_id: "page:boards/show"))

    assert_includes html, 'data-upkeep-page-frame="page:boards/show"'
  end

  def test_inserts_page_root_marker_after_html_doctype
    source = <<~ERB
      <!doctype html>
      <html>
        <body>Launch</body>
      </html>
    ERB
    manifest = build_manifest(path: "layouts/application", source: source)

    html = render_erb(instrument(manifest, source), PageContext.new(frame_id: "page:layouts/application"))

    assert_includes html, '<html data-upkeep-page-frame="page:layouts/application">'
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

  class PageContext
    def initialize(frame_id:)
      @frame_id = frame_id
    end

    def upkeep_page_frame_id
      @frame_id
    end
  end

  class RenderSiteContext
    attr_reader :render_site_ids, :manifest_paths, :manifest_fingerprints

    def initialize
      @render_site_ids = []
      @manifest_paths = []
      @manifest_fingerprints = []
    end

    def cards
      [Card.new("Plan")]
    end

    def upkeep_page_frame_id
      "page:boards/show"
    end

    def render(*args, partial: nil, collection: nil, as: nil)
      collection ||= args.first
      collection.map { |card| "<li>#{card.title}</li>" }.join
    end

    def tag
      TagBuilder.new(self)
    end

    def content_tag(name, options = {}, **kwargs)
      options = options.merge(kwargs)
      "<#{name}#{html_attributes(options)}>#{yield}</#{name}>"
    end

    def upkeep_frame(site_id, manifest_path: nil, manifest_fingerprint: nil)
      render_site_ids << site_id
      manifest_paths << manifest_path
      manifest_fingerprints << manifest_fingerprint
      yield
    end

    def html_attributes(options)
      return "" if options.empty?

      " " + options.map { |key, value| %(#{key}="#{value}") }.join(" ")
    end

    class TagBuilder
      def initialize(context)
        @context = context
      end

      def ul(options = {}, **kwargs)
        options = options.merge(kwargs)
        "<ul#{@context.html_attributes(options)}>#{yield}</ul>"
      end
    end
  end
end
