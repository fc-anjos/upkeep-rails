# frozen_string_literal: true

require_relative "shape"

module Upkeep
  module Subscriptions
    class Registrar
      Registration = Data.define(:identity, :decision, :subscription, :shape)

      def initialize(store:, shape_cache: ShapeCache.new)
        @store = store
        @shape_cache = shape_cache
      end

      def register(identity:, decision:, recorder:, metadata: {}, signature: nil)
        shape = shape_cache.resolve(recorder: recorder, decision: decision, signature: signature)
        subscription = store.register(
          subscriber_id: identity.subscriber_id,
          recorder: recorder,
          metadata: metadata.merge(
            shared_stream_names: shape.shared_stream_names,
            subscription_shape_key: shape.key,
            subscription_shape_cache: shape.cache_state
          ).compact,
          entries: shape.entries
        )

        Registration.new(identity, decision, subscription, shape)
      end

      private

      attr_reader :store, :shape_cache
    end
  end
end
