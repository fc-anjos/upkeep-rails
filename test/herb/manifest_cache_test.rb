# frozen_string_literal: true

require "test_helper"

class HerbManifestCacheTest < Minitest::Test
  def test_reuses_manifest_for_unchanged_source
    cache = Upkeep::HerbSupport::ManifestCache.new
    source = '<main><h1>Launch</h1><%= render partial: "cards/card", collection: cards, as: :card %></main>'

    first = cache.fetch(path: "boards/show", source: source)
    second = cache.fetch(path: "boards/show", source: source)

    assert_same first, second
    assert_equal "initial_build", cache.last_update_for("boards/show").fetch(:action)
    assert_equal({ "initial_build" => 1 }, cache.summary.fetch(:actions))
  end

  def test_classifies_content_only_source_updates
    cache = Upkeep::HerbSupport::ManifestCache.new
    old_source = '<main><h1 class="old">Launch</h1><%= render partial: "cards/card", collection: cards, as: :card %></main>'
    new_source = '<main><h1 class="new">Launch v2</h1><%= render partial: "cards/card", collection: cards, as: :card %></main>'

    cache.fetch(path: "boards/show", source: old_source)
    manifest = cache.fetch(path: "boards/show", source: new_source)
    update = cache.last_update_for("boards/show")

    assert_equal "refresh_manifest", update.fetch(:action)
    assert_equal "content_only_stable_topology", update.fetch(:reason)
    refute update.fetch(:topology_changed)
    assert manifest.parse.fetch(:ok)
  end

  def test_classifies_topology_updates
    cache = Upkeep::HerbSupport::ManifestCache.new
    old_source = '<main><%= render partial: "cards/card", collection: cards, as: :card %></main>'
    new_source = '<main><%= render partial: "cards/card", collection: visible_cards(cards), as: :card %></main>'

    cache.fetch(path: "boards/show", source: old_source)
    cache.fetch(path: "boards/show", source: new_source)
    update = cache.last_update_for("boards/show")

    assert_equal "rebuild_manifest", update.fetch(:action)
    assert_equal "manifest_topology_changed", update.fetch(:reason)
    assert update.fetch(:topology_changed)
  end
end
