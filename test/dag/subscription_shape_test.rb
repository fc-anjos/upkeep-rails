# frozen_string_literal: true

require "test_helper"

class SubscriptionShapeTest < Minitest::Test
  def test_recorder_trace_matches_finished_graph_signature
    recorder = Upkeep::Runtime::Recorder.new
    recorder.with_frame("fragment:cards/card:1", { kind: "fragment", template: "cards/_card" }) do
      recorder.record_dependency(card_title_dependency)
    end

    traced = recorder.subscription_shape(request_signature: signature)
    walked = Upkeep::DAG::SubscriptionShape.from_graph(recorder.graph, request_signature: signature)

    assert_equal walked.signature, traced.signature
  end

  def test_recorder_shape_falls_back_after_direct_graph_mutation
    recorder = Upkeep::Runtime::Recorder.new
    recorder.graph.add_node("fragment:manual", kind: :frame, payload: { kind: "fragment", template: "manual/_card" })
    recorder.graph.add_edge(Upkeep::Runtime::Recorder::REQUEST_NODE_ID, "fragment:manual", reason: :contains)

    assert_equal(
      Upkeep::DAG::SubscriptionShape.from_graph(recorder.graph, request_signature: signature).signature,
      recorder.subscription_shape(request_signature: signature).signature
    )
  end

  def test_non_shared_replay_payload_is_not_part_of_subscription_shape
    first = recorder_with_page_recipe(replay_token: "one")
    second = recorder_with_page_recipe(replay_token: "two")

    assert_equal(
      first.subscription_shape(request_signature: signature).signature,
      second.subscription_shape(request_signature: signature).signature
    )
  end

  def test_render_site_shared_stream_signature_is_part_of_subscription_shape
    first = recorder_with_render_site_recipe(replay_token: "one")
    second = recorder_with_render_site_recipe(replay_token: "two")

    refute_equal(
      first.subscription_shape(request_signature: signature).signature,
      second.subscription_shape(request_signature: signature).signature
    )
  end

  private

  def recorder_with_page_recipe(replay_token:)
    recorder = Upkeep::Runtime::Recorder.new
    recorder.with_frame(
      "page:cards/index",
      {
        kind: "page",
        template: "cards/index",
        recipe: fake_recipe(kind: :page, replay_token: replay_token)
      }
    ) {}
    recorder
  end

  def recorder_with_render_site_recipe(replay_token:)
    recorder = Upkeep::Runtime::Recorder.new
    recorder.with_frame(
      "site:public-cards",
      {
        kind: "render_site",
        site_id: "public-cards",
        recipe: fake_recipe(kind: :render_site, replay_token: replay_token)
      }
    ) {}
    recorder
  end

  def fake_recipe(kind:, replay_token:)
    Struct.new(:kind, :replay_token, keyword_init: true) do
      def to_h
        { kind: kind, replay: { token: replay_token } }
      end
    end.new(kind: kind, replay_token: replay_token)
  end

  def card_title_dependency
    Upkeep::Dependencies::ActiveRecordAttribute.new(
      table: "subscription_shape_cards",
      model: "SubscriptionShapeCard",
      id: 1,
      attribute: "title"
    )
  end

  def signature
    Upkeep::Capture::RequestSignature.new(
      "SubscriptionShapeCardsController",
      "index",
      "GET",
      "/cards"
    )
  end
end
