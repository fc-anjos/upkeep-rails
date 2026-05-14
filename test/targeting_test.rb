# frozen_string_literal: true

require "test_helper"

class TargetingTest < Minitest::Test
  def test_extracts_html_document_page_target
    target = Upkeep::Targeting::Target.new("page", "page:rails:layouts/application", "test")
    html = <<~HTML
      <!doctype html>
      <html data-upkeep-page-frame="page:rails:layouts/application">
        <body>Launch</body>
      </html>
    HTML

    target_html = Upkeep::Targeting::Extraction.extract_target_html(html, target)

    assert_includes target_html, 'data-upkeep-page-frame="page:rails:layouts/application"'
    assert_includes target_html, "Launch"
  end

  def test_patcher_replaces_html_document_page_target
    target = Upkeep::Targeting::Target.new("page", "page:rails:layouts/application", "test")
    initial_html = <<~HTML
      <!doctype html>
      <html data-upkeep-page-frame="page:rails:layouts/application">
        <body>Before</body>
      </html>
    HTML
    patch_html = <<~HTML
      <html data-upkeep-page-frame="page:rails:layouts/application">
        <body>After</body>
      </html>
    HTML

    patched = Upkeep::Targeting::Patcher.new(initial_html).apply([
      Upkeep::Targeting::Patch.new(target, patch_html)
    ])

    assert_includes patched, "After"
    refute_includes patched, "Before"
    assert_includes patched, 'data-upkeep-page-frame="page:rails:layouts/application"'
  end
end
