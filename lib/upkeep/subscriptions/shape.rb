# frozen_string_literal: true

require "active_support/notifications"
require "digest"
require_relative "../shared_streams"
require_relative "../version"
require_relative "reverse_index"

module Upkeep
  module Subscriptions
    class ShapeCache
      NOTIFICATION = "subscription_shape.upkeep"

      Shape = Data.define(:key, :entries, :shared_stream_names)
      Result = Data.define(:key, :entries, :shared_stream_names, :cache_state, :cacheable, :reason)
      TemplateSubscription = Data.define(:id, :subscriber_id, :recorder, :graph, :metadata)

      def initialize(index_builder: ReverseIndex.new)
        @index_builder = index_builder
        @shapes = {}
        @mutex = Mutex.new
      end

      def resolve(recorder:, decision:)
        if ActiveSupport::Notifications.notifier.listening?(NOTIFICATION)
          payload = {}
          ActiveSupport::Notifications.instrument(NOTIFICATION, payload) do
            result = resolve_without_instrumentation(recorder: recorder, decision: decision)
            payload.merge!(
              key: result.key,
              cache_state: result.cache_state,
              cacheable: result.cacheable,
              reason: result.reason,
              entries: result.entries.size,
              shared_stream_names: result.shared_stream_names.size
            )
            result
          end
        else
          resolve_without_instrumentation(recorder: recorder, decision: decision)
        end
      end

      def reset
        @mutex.synchronize { @shapes = {} }
      end

      private

      attr_reader :index_builder

      def resolve_without_instrumentation(recorder:, decision:)
        unless cacheable?(recorder, decision)
          shape = compile_shape(recorder, key: nil)
          return Result.new(nil, shape.entries, shape.shared_stream_names, "uncached", false, cache_bypass_reason(recorder, decision))
        end

        key = shape_key_for(recorder)
        @mutex.synchronize do
          if (shape = @shapes[key])
            Result.new(key, shape.entries, shape.shared_stream_names, "hit", true, nil)
          else
            shape = compile_shape(recorder, key: key)
            @shapes[key] = shape
            Result.new(key, shape.entries, shape.shared_stream_names, "miss", true, nil)
          end
        end
      end

      def cacheable?(recorder, decision)
        decision&.anonymous && recorder.reactive?
      end

      def cache_bypass_reason(recorder, decision)
        return "identified" unless decision&.anonymous
        return "refused_boundary" unless recorder.reactive?

        "uncacheable"
      end

      def compile_shape(recorder, key:)
        subscription = TemplateSubscription.new(nil, nil, recorder, recorder.graph, {})
        entries = index_builder.entries_for_subscription(subscription)
          .map { |entry| template_entry(entry) }
          .uniq { |entry| [entry.owner_id, entry.dependency_cache_key] }
          .freeze
        shared_stream_names = SharedStreams.names_for_recorder(recorder).freeze
        Shape.new(key, entries, shared_stream_names)
      end

      def template_entry(entry)
        ReverseIndex::Entry.new(
          nil,
          entry.owner_id,
          entry.dependency_cache_key,
          entry.dependency,
          nil,
          entry.cohort_key
        )
      end

      def shape_key_for(recorder)
        Digest::SHA256.hexdigest([
          "upkeep-subscription-shape",
          Upkeep::VERSION,
          recorder.to_h(dependencies: :all)
        ].inspect)
      end
    end
  end
end
