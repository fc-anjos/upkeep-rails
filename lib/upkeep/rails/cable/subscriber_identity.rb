# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Upkeep
  module Rails
    module Cable
      class UnidentifiedSubscriber < StandardError; end

      Identity = Data.define(:subscriber_id, :stream_name, :components)
      Decision = Data.define(:mode, :anonymous, :deopt_reason, :identity_sources, :identity_names)

      module SubscriberIdentity
        ANONYMOUS_PUBLIC_MODE = "anonymous_public"
        IDENTIFIED_MODE = "identified"
        DECLARATION_REQUIRED_SOURCES = %w[Current.user current_attribute warden_user].freeze

        module_function

        def derive(connection)
          derive_all(connection).last
        end

        def derive_all(connection)
          components = subscribe_components(connection, configuration.identity_definitions)
          raise UnidentifiedSubscriber, "ActionCable connection has no declared Upkeep identities" if components.empty?

          [for_components(components)]
        end

        def derive_for_subscription(connection, subscription)
          names = metadata_value(subscription, :identity_names) || []
          definitions = names.map { |name| configuration.identity_definition(name) }
          components = subscribe_components(connection, definitions)
          raise UnidentifiedSubscriber, "ActionCable connection did not resolve subscription identities #{names.inspect}" if components.empty?

          for_components(components)
        end

        def derive_from_request(request, recorder:, decision: decision_for(request, recorder: recorder))
          components = if decision.anonymous
            anonymous_components
          else
            recorder_components(recorder)
          end

          if components.empty?
            raise UnidentifiedSubscriber,
              "subscription has identity dependencies but no declared Upkeep identity mapping"
          end

          for_components(components)
        end

        def decision_for(_request = nil, recorder:)
          configured_dependencies = configured_identity_dependencies(recorder)
          undeclared_dependencies = undeclared_identity_dependencies(recorder)

          if configured_dependencies.any?
            Decision.new(
              IDENTIFIED_MODE,
              false,
              "identity_dependencies_present",
              configured_dependencies.map { |definition, _dependency| definition.source.to_s }.uniq.sort,
              configured_dependencies.map { |definition, _dependency| definition.name.to_s }.uniq.sort
            )
          elsif undeclared_dependencies.any?
            Decision.new(
              IDENTIFIED_MODE,
              false,
              "identity_setup_required",
              undeclared_dependencies.map { |dependency| dependency.source.to_s }.uniq.sort,
              []
            )
          else
            Decision.new(
              ANONYMOUS_PUBLIC_MODE,
              true,
              nil,
              [],
              []
            )
          end
        end

        def identifier_components(connection)
          identifiers = Array(connection.identifiers)
          identifiers.map { |name| component_for(name, connection.public_send(name)) }
        end

        def for_identifiers(identifiers)
          for_components(identifiers.map { |name, value| component_for(name, value) })
        end

        def for_components(components)
          canonical_bytes = JSON.generate(components.sort_by { |component| component.fetch(:name) })
          subscriber_id = "action_cable:#{Digest::SHA256.hexdigest(canonical_bytes)}"

          Identity.new(
            subscriber_id,
            Delivery::ActionCableAdapter.stream_name_for(subscriber_id),
            components
          )
        end

        def recorder_components(recorder)
          components_by_name = Hash.new { |hash, key| hash[key] = [] }
          configured_identity_dependencies(recorder).each do |definition, dependency|
            component = component_for_dependency(definition, dependency)
            components_by_name[definition.name] << component if component
          end

          components_by_name.map do |name, components|
            unique_components = components.uniq
            if unique_components.size > 1
              raise UnidentifiedSubscriber, "captured identity :#{name} changed during request"
            end

            unique_components.first
          end.compact
        end

        def anonymous_components
          [ scalar_component(:anonymous_public_subscription, SecureRandom.uuid) ]
        end

        def identity_dependencies(recorder)
          return [] unless recorder

          recorder.graph.dependency_nodes
            .map(&:payload)
            .select(&:identity?)
            .uniq(&:cache_key)
        end

        def configured_identity_dependencies(recorder)
          definitions = configuration.identity_definitions
          return [] if definitions.empty?

          identity_dependencies(recorder).flat_map do |dependency|
            definitions.select { |definition| definition.matches_dependency?(dependency) }
              .map { |definition| [definition, dependency] }
          end
        end

        def undeclared_identity_dependencies(recorder)
          identity_dependencies(recorder).select do |dependency|
            declaration_required_dependency?(dependency) &&
              configured_identity_dependencies_for_dependency(dependency).empty?
          end
        end

        def configured_identity_dependencies_for_dependency(dependency)
          configuration.identity_definitions.select { |definition| definition.matches_dependency?(dependency) }
        end

        def declaration_required_dependency?(dependency)
          DECLARATION_REQUIRED_SOURCES.include?(dependency.source.to_s)
        end

        def component_for_dependency(definition, dependency)
          if dependency_nil?(dependency)
            raise UnidentifiedSubscriber, "captured identity :#{definition.name} from #{definition.source_label} is nil"
          end

          identity_component(definition.name, dependency.key.fetch(:value))
        end

        def subscribe_components(connection, definitions)
          definitions.filter_map do |definition|
            value = call_subscribe_block(definition, connection)
            if value.nil?
              raise UnidentifiedSubscriber, "subscribe identity :#{definition.name} from #{definition.source_label} is nil"
            end

            identity_component(definition.name, subscribe_identity_value(definition, value))
          end
        end

        def call_subscribe_block(definition, connection)
          block = definition.subscribe_block
          block.arity == 1 ? block.call(connection) : connection.instance_exec(&block)
        end

        def subscribe_identity_value(definition, value)
          case definition.source
          when :session, :cookie
            Dependencies.private_fingerprint(value)
          else
            canonical_identity_value(value)
          end
        end

        def identity_component(name, value)
          {
            name: name.to_s,
            kind: "identity",
            value: normalize_component_value(value)
          }
        end

        def canonical_identity_value(value)
          case value
          when nil, true, false, Numeric, String, Symbol
            value
          when Array
            value.map { |item| canonical_identity_value(item) }
          when Hash
            value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, canonical_identity_value(value.fetch(key))] }
          else
            model_identity = Dependencies.model_identity(value)
            return model_identity if model_identity

            return { global_id: value.to_gid_param } if value.respond_to?(:to_gid_param)

            raise UnidentifiedSubscriber, "identity value #{value.class.name} has no canonical identity"
          end
        end

        def normalize_component_value(value)
          case value
          when Hash
            value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, normalize_component_value(value.fetch(key))] }
          when Array
            value.map { |item| normalize_component_value(item) }
          when Symbol
            value.to_s
          else
            value
          end
        end

        def dependency_nil?(dependency)
          value = dependency.key.fetch(:value)
          return true if value.nil?

          dependency.metadata[:value_class].to_s == "NilClass" ||
            dependency.metadata["value_class"].to_s == "NilClass"
        end

        def model_component(name, identity)
          return unless identity.is_a?(Hash) && identity[:model] && identity[:id]

          {
            name: name.to_s,
            kind: "model",
            model: identity.fetch(:model),
            id: identity.fetch(:id).to_s
          }
        end

        def component_for(name, value)
          raise UnidentifiedSubscriber, "ActionCable identifier #{name} is nil" if value.nil?

          if active_record?(value)
            active_record_component(name, value)
          elsif scalar?(value)
            scalar_component(name, value)
          elsif value.respond_to?(:to_gid_param)
            global_id_component(name, value)
          else
            raise UnidentifiedSubscriber, "ActionCable identifier #{name} has no canonical identity"
          end
        end

        def active_record?(value)
          defined?(::ActiveRecord::Base) && value.is_a?(::ActiveRecord::Base)
        end

        def active_record_component(name, record)
          raise UnidentifiedSubscriber, "ActionCable identifier #{name} is an unsaved record" unless record.id

          model_component(name, model: record.class.name, id: record.id)
        end

        def scalar?(value)
          value.is_a?(String) ||
            value.is_a?(Symbol) ||
            value.is_a?(Integer) ||
            value == true ||
            value == false
        end

        def scalar_component(name, value)
          {
            name: name.to_s,
            kind: "scalar",
            class: value.class.name,
            value: value.to_s
          }
        end

        def global_id_component(name, value)
          {
            name: name.to_s,
            kind: "global_id",
            value: value.to_gid_param
          }
        end

        def metadata_value(subscription, key)
          subscription.metadata[key] || subscription.metadata[key.to_s]
        end

        def configuration
          Upkeep::Rails.configuration
        end
      end
    end
  end
end
