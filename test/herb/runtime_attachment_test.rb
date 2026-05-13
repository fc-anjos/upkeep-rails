# frozen_string_literal: true

require "test_helper"

class HerbRuntimeAttachmentTest < Minitest::Test
  def test_rendered_frames_carry_manifest_provenance
    Upkeep::Domain::Database.reset!
    Upkeep::Domain::Database.seed!

    board = Upkeep::Domain::Board.find_by!(name: "Launch")
    result = Upkeep::Rendering::Engine.new.render_request(
      "boards/collection",
      -> { { board: board, cards: board.cards.order(:position) } }
    )
    summary = result.recorder.graph.summary
    manifests = Upkeep::HerbSupport::RuntimeAlignment.build_manifests(Upkeep::Templates::REGISTRY.values)

    report = Upkeep::HerbSupport::RuntimeAlignment.new(manifests: manifests).report(graph: result.recorder.graph)

    assert_equal summary.fetch(:frames), summary.fetch(:manifest_attached_frames)
    assert report.fetch(:summary).fetch(:gate_passed)
    assert_equal summary.fetch(:frames), report.fetch(:summary).fetch(:matched_frames)
    assert_empty report.fetch(:summary).fetch(:frame_deopt_reasons)
  end
end
