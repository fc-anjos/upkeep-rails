# frozen_string_literal: true

require "action_controller"
require "stringio"

module Upkeep
  module Rails
    module Replay
      module_function

      def render(recipe)
        replay = symbolize_keys(recipe.replay)

        case replay.fetch(:type)
        when "controller_page"
          render_controller_page(replay)
        when "template"
          render_template(replay)
        when "fragment"
          render_fragment(replay)
        when "collection"
          render_collection(replay)
        else
          raise "unknown Rails replay recipe type: #{replay.fetch(:type).inspect}"
        end
      end

      def render_controller_page(replay)
        controller = constantize(replay.fetch(:controller_class))
        _status, _headers, body = controller.action(replay.fetch(:action)).call(rack_env(replay.fetch(:env)))
        collect_response_body(body)
      end

      def render_template(replay)
        renderer_for(replay).render(
          template: replay.fetch(:template),
          locals: revive_hash(replay.fetch(:locals, {}))
        )
      end

      def render_fragment(replay)
        renderer_for(replay).render(
          partial: partial_path(replay.fetch(:template)),
          locals: revive_hash(replay.fetch(:locals, {}))
        )
      end

      def render_collection(replay)
        options = revive_hash(replay.fetch(:options, {}))
        collection = revive_value(replay.fetch(:collection))

        if replay.fetch(:partial) == "derived"
          renderer_for(replay).render(collection)
        else
          renderer_for(replay).render(options.merge(
            partial: replay.fetch(:partial),
            collection: collection
          ))
        end
      end

      def renderer_for(replay)
        if replay[:controller_class]
          constantize(replay.fetch(:controller_class)).renderer
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
        values.each_with_object({}) do |(key, value), revived|
          revived[key.to_sym] = revive_value(value)
        end
      end

      def revive_value(snapshot)
        snapshot = symbolize_keys(snapshot)

        case snapshot.fetch(:type)
        when "active_record"
          constantize(snapshot.fetch(:model)).find(snapshot.fetch(:id))
        when "active_record_relation"
          constantize(snapshot.fetch(:model)).find_by_sql(snapshot.fetch(:sql))
        when "array"
          snapshot.fetch(:items).map { |item| revive_value(item) }
        when "hash"
          revive_hash(snapshot.fetch(:entries))
        when "literal"
          snapshot[:value]
        else
          raise "unknown Rails replay value type: #{snapshot.fetch(:type).inspect}"
        end
      end

      def revive_env_value(value)
        case value
        when Hash
          value.transform_values { |nested_value| revive_env_value(nested_value) }
        when Array
          value.map { |nested_value| revive_env_value(nested_value) }
        else
          value
        end
      end

      def partial_path(template)
        template.to_s.sub(%r{(^|/)_([^/]+)\z}, "\\1\\2")
      end

      def constantize(name)
        name.to_s.split("::").reduce(Object) { |namespace, constant_name| namespace.const_get(constant_name) }
      end

      def collect_response_body(body)
        body.each.to_a.join
      ensure
        body.close if body.respond_to?(:close)
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
end
