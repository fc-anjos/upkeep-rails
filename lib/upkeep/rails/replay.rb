# frozen_string_literal: true

require "action_controller"
require "active_support/hash_with_indifferent_access"
require "stringio"

module Upkeep
  module Rails
    module Replay
      module_function

      class RackSession < ActiveSupport::HashWithIndifferentAccess
        def enabled? = true

        def loaded? = true

        def id = self[:session_id]

        def id_was = id
      end

      def render(recipe)
        replay = recipe.replay

        case replay
        when ::Upkeep::Replay::ControllerPage
          render_controller_page(replay)
        when ::Upkeep::Replay::Template
          render_template(replay)
        when ::Upkeep::Replay::Fragment
          render_fragment(replay)
        when ::Upkeep::Replay::Collection
          render_collection(replay)
        when ::Upkeep::Replay::CollectionMember
          render_collection_member(replay)
        else
          raise "unknown Rails replay recipe type: #{replay.class.name}"
        end
      end

      def render_controller_page(replay)
        controller = constantize(replay.controller_class)
        _status, _headers, body = ControllerRuntime.suppress do
          controller.action(replay.action).call(rack_env(replay.env))
        end
        collect_response_body(body)
      end

      def render_template(replay)
        renderer_for(replay).render(
          template: replay.template,
          locals: revive_hash(replay.locals)
        )
      end

      def render_fragment(replay)
        renderer_for(replay).render(
          partial: partial_path(replay.template),
          locals: revive_hash(replay.locals)
        )
      end

      def render_collection(replay)
        options = revive_hash(replay.options)
        collection = revive_value(replay.collection)

        if replay.derived_partial?
          renderer_for(replay).render(collection)
        else
          renderer_for(replay).render(options.merge(
            partial: replay.partial,
            collection: collection
          ))
        end
      end

      def render_collection_member(replay)
        options = revive_hash(replay.options)
        record = revive_value(replay.record)
        locals = options.fetch(:locals, {})
        local_name = (options[:as] || inferred_local_name(replay.partial)).to_sym

        renderer_for(replay).render(
          partial: replay.partial,
          locals: locals.merge(local_name => record)
        )
      end

      def renderer_for(replay)
        if replay.controller_class
          constantize(replay.controller_class).renderer
        else
          ::ActionController::Base.renderer
        end
      end

      def rack_env(env)
        env = env.each_with_object({}) { |(key, value), copy| copy[key.to_s] = revive_env_value(value) }
        env["rack.input"] = StringIO.new
        env["rack.errors"] ||= StringIO.new
        env
      end

      def revive_hash(values)
        values = values.entries if values.is_a?(::Upkeep::Replay::HashValue)

        values.each_with_object({}) do |(key, value), revived|
          revived[key.to_sym] = revive_value(value)
        end
      end

      def revive_value(snapshot)
        snapshot = ::Upkeep::Replay.value(snapshot)

        case snapshot
        when ::Upkeep::Replay::ActiveRecordValue
          constantize(snapshot.model).find(snapshot.id)
        when ::Upkeep::Replay::ActiveRecordRelationValue
          constantize(snapshot.model).find_by_sql(snapshot.sql)
        when ::Upkeep::Replay::ArrayValue
          snapshot.items.map { |item| revive_value(item) }
        when ::Upkeep::Replay::HashValue
          revive_hash(snapshot.entries)
        when ::Upkeep::Replay::LiteralValue
          snapshot.value
        else
          raise "unsupported Rails replay value type: #{snapshot.class.name}"
        end
      end

      def revive_env_value(value)
        return revive_replay_session(value) if replay_session_snapshot?(value)

        case value
        when Hash
          value.transform_values { |nested_value| revive_env_value(nested_value) }
        when Array
          value.map { |nested_value| revive_env_value(nested_value) }
        else
          value
        end
      end

      def replay_session_snapshot?(value)
        return false unless value.is_a?(Hash)

        type = value["__upkeep_replay_type"] || value[:__upkeep_replay_type]
        type == "rack_session"
      end

      def revive_replay_session(snapshot)
        values = snapshot["values"] || snapshot[:values] || {}
        RackSession.new(revive_env_value(values))
      end

      def partial_path(template)
        template.to_s.sub(%r{(^|/)_([^/]+)\z}, "\\1\\2")
      end

      def inferred_local_name(partial)
        File.basename(partial.to_s).sub(/\A_/, "").to_sym
      end

      def constantize(name)
        name.to_s.split("::").reduce(Object) { |namespace, constant_name| namespace.const_get(constant_name) }
      end

      def collect_response_body(body)
        body.each.to_a.join
      ensure
        body.close if body.respond_to?(:close)
      end

    end
  end
end
