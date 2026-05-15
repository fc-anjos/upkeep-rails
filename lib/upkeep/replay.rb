# frozen_string_literal: true

module Upkeep
  module Replay
    module Payload
      module_function

      def from_h(snapshot)
        return snapshot if snapshot.is_a?(Payload)

        snapshot = Replay.symbolize_keys(snapshot || {})
        return Empty.new if snapshot.empty?

        case snapshot.fetch(:type).to_s
        when "controller_page"
          ControllerPage.new(
            controller_class: snapshot[:controller_class],
            action: snapshot.fetch(:action),
            env: snapshot.fetch(:env)
          )
        when "template"
          Template.new(
            controller_class: snapshot[:controller_class],
            template: snapshot.fetch(:template),
            locals: Replay.value_hash_from_h(snapshot.fetch(:locals))
          )
        when "fragment"
          Fragment.new(
            controller_class: snapshot[:controller_class],
            template: snapshot.fetch(:template),
            locals: Replay.value_hash_from_h(snapshot.fetch(:locals))
          )
        when "collection"
          Collection.new(
            controller_class: snapshot[:controller_class],
            partial: snapshot.fetch(:partial),
            collection: Value.from_h(snapshot.fetch(:collection)),
            options: Replay.value_hash_from_h(snapshot.fetch(:options))
          )
        when "collection_member"
          CollectionMember.new(
            controller_class: snapshot[:controller_class],
            partial: snapshot.fetch(:partial),
            record: Value.from_h(snapshot.fetch(:record)),
            options: Replay.value_hash_from_h(snapshot.fetch(:options))
          )
        else
          raise ArgumentError, "unknown replay payload type: #{snapshot.fetch(:type).inspect}"
        end
      end

      def empty?
        false
      end
    end

    module Value
      module_function

      def from_h(snapshot)
        return snapshot if snapshot.is_a?(Value)
        return LiteralValue.new(value: snapshot) unless snapshot.is_a?(Hash)

        snapshot = Replay.symbolize_keys(snapshot)

        case snapshot.fetch(:type).to_s
        when "active_record"
          ActiveRecordValue.new(
            model: snapshot.fetch(:model),
            id: snapshot.fetch(:id)
          )
        when "active_record_relation"
          ActiveRecordRelationValue.new(
            model: snapshot.fetch(:model),
            sql: snapshot.fetch(:sql),
            primary_key: snapshot[:primary_key],
            appendable: snapshot.fetch(:appendable),
            predicates: snapshot.fetch(:predicates),
            member_ids: snapshot.fetch(:member_ids)
          )
        when "array"
          ArrayValue.new(items: snapshot.fetch(:items).map { |item| from_h(item) })
        when "hash"
          HashValue.new(entries: Replay.value_hash_from_h(snapshot.fetch(:entries)))
        when "literal"
          LiteralValue.new(value: snapshot[:value])
        when "unsupported"
          UnsupportedValue.new(class_name: snapshot.fetch(:class))
        when "refused_active_record_relation"
          RefusedActiveRecordRelationValue.new(
            model: snapshot.fetch(:model),
            sql_digest: snapshot.fetch(:sql_digest),
            reason: snapshot.fetch(:reason)
          )
        else
          raise ArgumentError, "unknown replay value type: #{snapshot.fetch(:type).inspect}"
        end
      end
    end

    class Empty
      include Payload

      def empty?
        true
      end

      def to_h
        {}
      end
    end

    class ControllerPage < Data.define(:controller_class, :action, :env)
      include Payload

      def type = "controller_page"

      def to_h
        {
          type: type,
          controller_class: controller_class,
          action: action,
          env: env
        }.compact
      end
    end

    class Template < Data.define(:controller_class, :template, :locals)
      include Payload

      def type = "template"

      def to_h
        {
          type: type,
          controller_class: controller_class,
          template: template,
          locals: Replay.value_hash_to_h(locals)
        }.compact
      end
    end

    class Fragment < Data.define(:controller_class, :template, :locals)
      include Payload

      def type = "fragment"

      def to_h
        {
          type: type,
          controller_class: controller_class,
          template: template,
          locals: Replay.value_hash_to_h(locals)
        }.compact
      end
    end

    class Collection < Data.define(:controller_class, :partial, :collection, :options)
      include Payload

      def type = "collection"

      def derived_partial?
        partial == "derived"
      end

      def to_h
        {
          type: type,
          controller_class: controller_class,
          partial: partial,
          collection: collection.to_h,
          options: Replay.value_hash_to_h(options)
        }.compact
      end
    end

    class CollectionMember < Data.define(:controller_class, :partial, :record, :options)
      include Payload

      def type = "collection_member"

      def to_h
        {
          type: type,
          controller_class: controller_class,
          partial: partial,
          record: record.to_h,
          options: Replay.value_hash_to_h(options)
        }.compact
      end
    end

    class ActiveRecordValue < Data.define(:model, :id)
      include Value

      def type = "active_record"

      def to_h
        { type: type, model: model, id: id }
      end
    end

    class ActiveRecordRelationValue < Data.define(:model, :sql, :primary_key, :appendable, :predicates, :member_ids)
      include Value

      def type = "active_record_relation"

      def appendable?
        !!appendable
      end

      def to_h
        {
          type: type,
          model: model,
          sql: sql,
          primary_key: primary_key,
          appendable: appendable,
          predicates: predicates,
          member_ids: member_ids
        }.compact
      end
    end

    class ArrayValue < Data.define(:items)
      include Value

      def type = "array"

      def to_h
        { type: type, items: items.map(&:to_h) }
      end
    end

    class HashValue < Data.define(:entries)
      include Value

      def type = "hash"

      def to_h
        { type: type, entries: Replay.value_hash_to_h(entries) }
      end
    end

    class LiteralValue < Data.define(:value)
      include Value

      def type = "literal"

      def to_h
        { type: type, value: value }
      end
    end

    class UnsupportedValue < Data.define(:class_name)
      include Value

      def type = "unsupported"

      def to_h
        { type: type, class: class_name }
      end
    end

    class RefusedActiveRecordRelationValue < Data.define(:model, :sql_digest, :reason)
      include Value

      def type = "refused_active_record_relation"

      def to_h
        {
          type: type,
          model: model,
          sql_digest: sql_digest,
          reason: reason
        }
      end
    end

    module_function

    def payload(value)
      Payload.from_h(value)
    end

    def value(value)
      Value.from_h(value)
    end

    def value_hash_from_h(values)
      values.to_h.each_with_object({}) do |(key, nested_value), snapshot|
        snapshot[key.to_s] = Value.from_h(nested_value)
      end
    end

    def value_hash_to_h(values)
      values.to_h.each_with_object({}) do |(key, nested_value), snapshot|
        snapshot[key] = Value.from_h(nested_value).to_h
      end
    end

    def active_record_value(record)
      ActiveRecordValue.new(model: record.class.name, id: record.id)
    end

    class Recipe
      attr_reader :kind, :frame_id, :target_kind, :target_id, :template, :metadata, :runtime, :replay

      def initialize(kind:, frame_id:, target_kind:, target_id:, template: nil, metadata: {}, runtime: nil, replay: nil, &renderer)
        @kind = kind
        @frame_id = frame_id
        @target_kind = target_kind
        @target_id = target_id
        @template = template
        @metadata = metadata
        @runtime = runtime
        @replay = Replay.payload(replay)
        @renderer = renderer
      end

      def render
        return @renderer.call if @renderer

        runtime_renderer.render(self)
      end

      def render_target(target)
        html = render
        return html if target_match?(target)

        require_relative "targeting"
        Targeting::Extraction.extract_target_html(html, target)
      end

      def target_match?(target)
        target && target.kind != "page" && target.kind == target_kind && target.id == target_id
      end

      def manifest_target_render?(target)
        !!manifest_reference && target_match?(target)
      end

      def manifest_reference
        metadata[:manifest] || metadata["manifest"]
      end

      def to_h
        snapshot = {
          kind: kind,
          frame_id: frame_id,
          target_kind: target_kind,
          target_id: target_id,
          template: template,
          metadata: metadata
        }.compact

        snapshot[:runtime] = runtime if runtime
        replay_snapshot = replay&.to_h
        snapshot[:replay] = replay_snapshot if replay_snapshot && !replay_snapshot.empty?
        snapshot
      end

      def self.from_h(snapshot)
        snapshot = Replay.symbolize_keys(snapshot)

        new(
          kind: snapshot.fetch(:kind),
          frame_id: snapshot.fetch(:frame_id),
          target_kind: snapshot.fetch(:target_kind),
          target_id: snapshot.fetch(:target_id),
          template: snapshot[:template],
          metadata: snapshot.fetch(:metadata),
          runtime: snapshot[:runtime],
          replay: snapshot.fetch(:replay, {})
        )
      end

      private

      def runtime_renderer
        case runtime
        when "rails"
          require_relative "rails/replay"
          Upkeep::Rails::Replay
        else
          raise "replay recipe has no renderer"
        end
      end
    end

    def symbolize_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), result|
          normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          result[normalized_key] = symbolize_keys(nested_value)
        end
      when Array
        value.map { |nested_value| symbolize_keys(nested_value) }
      else
        value
      end
    end
  end
end
