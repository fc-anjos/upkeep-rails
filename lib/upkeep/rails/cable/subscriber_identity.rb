# frozen_string_literal: true

require "digest"
require "json"

module Upkeep
  module Rails
    module Cable
      class UnidentifiedSubscriber < StandardError; end

      Identity = Data.define(:subscriber_id, :stream_name, :components)

      module SubscriberIdentity
        module_function

        def derive(connection)
          identifiers = Array(connection.identifiers)
          raise UnidentifiedSubscriber, "ActionCable connection has no server identifiers" if identifiers.empty?

          for_identifiers(identifiers.to_h { |name| [name.to_sym, connection.public_send(name)] })
        end

        def for_identifiers(identifiers)
          components = identifiers.map { |name, value| component_for(name, value) }
          canonical_bytes = JSON.generate(components.sort_by { |component| component.fetch(:name) })
          subscriber_id = "action_cable:#{Digest::SHA256.hexdigest(canonical_bytes)}"

          Identity.new(
            subscriber_id,
            Delivery::ActionCableAdapter.stream_name_for(subscriber_id),
            components
          )
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

          {
            name: name.to_s,
            kind: "active_record",
            model: record.class.name,
            table: record.class.table_name,
            id: record.id.to_s
          }
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
      end
    end
  end
end
