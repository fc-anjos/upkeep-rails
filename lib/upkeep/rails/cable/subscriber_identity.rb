# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Upkeep
  module Rails
    module Cable
      class UnidentifiedSubscriber < StandardError; end

      Identity = Data.define(:subscriber_id, :stream_name, :components)
      Decision = Data.define(:mode, :anonymous, :deopt_reason, :identity_sources)

      module SubscriberIdentity
        ANONYMOUS_PUBLIC_MODE = "anonymous_public"
        IDENTIFIED_MODE = "identified"
        CONNECTION_IDENTITY_SOURCES = %w[Current.user cookie current_attribute session warden_user].freeze

        module_function

        def derive(connection)
          derive_all(connection).last
        end

        def derive_all(connection)
          identities = []
          request_components = request_components(connection.request) if connection.respond_to?(:request)
          identifier_components = identifier_components(connection)

          identities << for_components(request_components) if request_components&.any?
          identities << for_components(Array(request_components) + identifier_components) if identifier_components.any?
          identities = identities.uniq(&:subscriber_id)

          raise UnidentifiedSubscriber, "ActionCable connection has no server identifiers" if identities.empty?

          identities
        end

        def derive_from_request(request, recorder:, decision: decision_for(request, recorder: recorder))
          components = if decision.anonymous
            anonymous_components
          else
            request_components(request) + recorder_components(recorder)
          end

          if components.empty?
            raise UnidentifiedSubscriber,
              "subscription has identity dependencies but no canonical request or recorder identity"
          end

          for_components(components)
        end

        def decision_for(_request = nil, recorder:)
          dependencies = identity_dependencies(recorder)
          if dependencies.empty?
            Decision.new(ANONYMOUS_PUBLIC_MODE, true, nil, [])
          else
            Decision.new(
              IDENTIFIED_MODE,
              false,
              "identity_dependencies_present",
              dependencies.map { |dependency| dependency.source.to_s }.uniq.sort
            )
          end
        end

        def identifier_components(connection)
          identifiers = Array(connection.identifiers)
          identifiers.map { |name| component_for(name, connection.public_send(name)) }
        end

        def request_components(request)
          session_id = session_id_for(request)
          return [] unless session_id

          [scalar_component(:rails_session, session_id)]
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
          identity_dependencies(recorder)
            .filter_map { |dependency| component_for_dependency(dependency) }
            .uniq
        end

        def anonymous_components
          [ scalar_component(:anonymous_public_subscription, SecureRandom.uuid) ]
        end

        def identity_dependencies(recorder)
          return [] unless recorder

          recorder.graph.dependency_nodes
            .map(&:payload)
            .select(&:identity?)
            .select { |dependency| connection_identity_dependency?(dependency) }
            .uniq(&:cache_key)
        end

        def connection_identity_dependency?(dependency)
          CONNECTION_IDENTITY_SOURCES.include?(dependency.source.to_s)
        end

        def component_for_dependency(dependency)
          if dependency.source == :current_attribute && current_user_dependency?(dependency)
            model_component(:current_user, dependency.key.fetch(:value))
          elsif dependency.source == "Current.user"
            model_component(:current_user, dependency.metadata)
          elsif dependency.source == :warden_user
            model_component(:"warden_#{dependency.metadata.fetch(:scope)}", dependency.key.fetch(:value))
          end
        end

        def current_user_dependency?(dependency)
          dependency.metadata.fetch(:name) == "user"
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

        def session_id_for(request)
          return unless request&.respond_to?(:session)

          session = request.session
          session_id = session.id if session.respond_to?(:id)
          session_id = session_id.public_id if session_id.respond_to?(:public_id)
          session_id = session_id.private_id if session_id.respond_to?(:private_id)
          session_id = session[:session_id] if blank?(session_id) && session.respond_to?(:[])

          session_id.to_s unless blank?(session_id)
        rescue StandardError
          nil
        end

        def blank?(value)
          value.nil? || value == ""
        end
      end
    end
  end
end
