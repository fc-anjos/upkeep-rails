# frozen_string_literal: true

require "test_helper"

class HerbManifestReplayTest < Minitest::Test
  def test_replay_recipes_reference_their_runtime_manifest
    Upkeep::Domain::Database.reset!
    Upkeep::Domain::Database.seed!

    board = Upkeep::Domain::Board.find_by!(name: "Launch")
    result = Upkeep::Rendering::Engine.new.render_request(
      "boards/collection",
      -> { { board: board, cards: board.cards.order(:position) } }
    )

    result.recorder.graph.frame_nodes.each do |frame|
      recipe = frame.payload.fetch(:recipe)
      expected_manifest = {
        path: frame.payload.fetch(:manifest_path),
        fingerprint: frame.payload.fetch(:manifest_fingerprint)
      }

      assert_equal expected_manifest, recipe.manifest_reference
      assert_equal expected_manifest, Upkeep::Replay::Recipe.from_h(recipe.to_h).manifest_reference

      target = Upkeep::Targeting::Target.new(recipe.target_kind, recipe.target_id, "test")
      if target.kind == "page"
        refute recipe.manifest_target_render?(target)
        assert_equal Upkeep::Targeting::Extraction.extract_target_html(recipe.render, target), recipe.render_target(target)
      else
        assert recipe.manifest_target_render?(target)
        assert_equal recipe.render, recipe.render_target(target)
      end
    end
  end
end
