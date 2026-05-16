# frozen_string_literal: true

require "active_support/notifications"
require_relative "../shared_streams"
require_relative "reverse_index"

module Upkeep
  module Subscriptions
    class ShapeCache
      NOTIFICATION = "subscription_shape.upkeep"

      Shape = Data.define(:key, :entries, :shared_stream_names)
      Result = Data.define(:key, :entries, :shared_stream_names, :cache_state, :cacheable, :reason, :timings)
      TemplateSubscription = Data.define(:id, :subscriber_id, :recorder, :graph, :metadata)

      def initialize(index_builder: ReverseIndex.new)
        @index_builder = index_builder
        @shapes = {}
        @mutex = Mutex.new
      end

      def resolve(recorder:, decision:, signature: nil)
        if ActiveSupport::Notifications.notifier.listening?(NOTIFICATION)
          payload = {}
          ActiveSupport::Notifications.instrument(NOTIFICATION, payload) do
            result = resolve_without_instrumentation(recorder: recorder, decision: decision, signature: signature)
            payload.merge!(
              key: result.key,
              cache_state: result.cache_state,
              cacheable: result.cacheable,
              reason: result.reason,
              entries: result.entries.size,
              shared_stream_names: result.shared_stream_names.size
            )
            payload.merge!(result.timings)
            result
          end
        else
          resolve_without_instrumentation(recorder: recorder, decision: decision, signature: signature)
        end
      end

      def reset
        @mutex.synchronize { @shapes = {} }
      end

      private

      attr_reader :index_builder

      def resolve_without_instrumentation(recorder:, decision:, signature:)
        timings = {}
        unless cacheable?(recorder, decision)
          shape = measure(timings, :compile_ms) { compile_shape(recorder, key: nil, timings: timings) }
          return Result.new(nil, shape.entries, shape.shared_stream_names, "uncached", false, cache_bypass_reason(recorder, decision), timings)
        end

        key = measure(timings, :key_ms) { shape_key_for(recorder, signature: signature) }
        @mutex.synchronize do
          if (shape = @shapes[key])
            Result.new(key, shape.entries, shape.shared_stream_names, "hit", true, nil, timings)
          else
            shape = measure(timings, :compile_ms) { compile_shape(recorder, key: key, timings: timings) }
            @shapes[key] = shape
            Result.new(key, shape.entries, shape.shared_stream_names, "miss", true, nil, timings)
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

      def compile_shape(recorder, key:, timings:)
        subscription = TemplateSubscription.new(nil, nil, recorder, recorder.graph, { subscription_shape_key: key }.compact)
        entries = measure(timings, :index_template_ms) do
          index_builder.entries_for_subscription(subscription)
        end
          .map { |entry| template_entry(entry) }
          .uniq { |entry| [entry.owner_id, entry.dependency_cache_key] }
          .freeze
        shared_stream_names = measure(timings, :shared_stream_names_ms) { SharedStreams.names_for_recorder(recorder) }.freeze
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

      def shape_key_for(recorder, signature:)
        recorder.subscription_shape(request_signature: signature).signature
      end

      def measure(timings, key)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        timings[key] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(3)
      end
    end
  end
end
