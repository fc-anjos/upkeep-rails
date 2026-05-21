# frozen_string_literal: true

require "test_helper"

class SubscriptionShapeCacheTest < Minitest::Test
  def test_anonymous_shape_key_does_not_serialize_full_recorder_snapshot
    recorder = recorder_with_dependency
    recorder.define_singleton_method(:to_h) do |*|
      raise "shape key should not serialize the full recorder"
    end
    decision = Upkeep::Rails::Cable::Decision.new(
      Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE,
      true,
      nil,
      [],
      []
    )
    cache = Upkeep::Subscriptions::ShapeCache.new

    first = cache.resolve(recorder: recorder, decision: decision, signature: signature)
    second = cache.resolve(recorder: recorder, decision: decision, signature: signature)

    assert_equal "miss", first.cache_state
    assert_equal "hit", second.cache_state
    assert_equal first.key, second.key
    assert first.entries.all? { |entry| entry.cohort_key == first.key }
  end

  private

  def recorder_with_dependency
    recorder = Upkeep::Runtime::Recorder.new
    recorder.record_dependency(
      Upkeep::Dependencies::ActiveRecordAttribute.new(
        table: "subscription_shape_cards",
        model: "SubscriptionShapeCard",
        id: 1,
        attribute: "title"
      )
    )
    recorder
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
