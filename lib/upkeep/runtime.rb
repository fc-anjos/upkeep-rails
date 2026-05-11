# frozen_string_literal: true

require "active_record"
require "active_support/notifications"
require "digest"

module Upkeep
  module Runtime
    module Observation
      THREAD_KEY = :upkeep_recorder

      module_function

      def capture_request
        previous = Thread.current[THREAD_KEY]
        recorder = Recorder.new
        Thread.current[THREAD_KEY] = recorder

        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA"

          record({
            type: "sql",
            name: payload[:name],
            sql: payload[:sql],
            table: table_from_sql(payload[:sql]),
            columns: columns_from_sql(payload[:sql])
          })
        end

        result = yield(recorder)
        [result, recorder]
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        Thread.current[THREAD_KEY] = previous
      end

      def capture_frame(frame_id, metadata = {})
        recorder = Thread.current[THREAD_KEY]
        return yield unless recorder

        recorder.with_frame(frame_id, metadata) { yield }
      end

      def record(event)
        Thread.current[THREAD_KEY]&.record(event)
      end

      def record_dependency(dependency, event:)
        Thread.current[THREAD_KEY]&.record_dependency(dependency, event: event)
      end

      def recorder
        Thread.current[THREAD_KEY]
      end

      def table_from_sql(sql)
        sql[/FROM\s+"([^"]+)"/i, 1] || sql[/UPDATE\s+"([^"]+)"/i, 1] || sql[/INSERT\s+INTO\s+"([^"]+)"/i, 1]
      end

      def columns_from_sql(sql)
        sql.scan(/"[^"]+"\."([^"]+)"/).flatten.uniq.sort
      end
    end

    class Recorder
      REQUEST_NODE_ID = :request

      attr_reader :events_by_frame, :request_events, :frame_metadata, :graph

      def initialize
        @events_by_frame = Hash.new { |hash, key| hash[key] = [] }
        @request_events = []
        @frame_metadata = {}
        @frame_stack = []
        @graph = DAG::Graph.new
        @graph.add_node(REQUEST_NODE_ID, kind: :request, payload: {})
      end

      def with_frame(frame_id, metadata)
        @frame_metadata[frame_id] ||= metadata
        @graph.add_node(frame_id, kind: :frame, payload: metadata)
        @graph.add_edge(current_owner, frame_id, reason: :contains)
        @frame_stack.push(frame_id)
        yield
      ensure
        @frame_stack.pop
      end

      def record(event)
        if current_frame
          @events_by_frame[current_frame] << event
        else
          @request_events << event
        end
      end

      def record_dependency(dependency, event:)
        record(event)
        @graph.add_dependency(current_owner, dependency)
      end

      def current_frame
        @frame_stack.last
      end

      def current_owner
        current_frame || REQUEST_NODE_ID
      end

      def identity_profile(frame_id)
        @graph.dependencies_for(frame_id).select(&:identity?).map(&:to_h)
      end

      def identity_signature(frame_id)
        identity_dependencies = @graph.dependencies_for(frame_id).select(&:identity?)
        return "public" if identity_dependencies.empty?

        Digest::SHA256.hexdigest(identity_dependencies.map(&:identity_key).sort_by(&:inspect).inspect)[0, 16]
      end
    end

    module ChangeLog
      @events = []

      module_function

      def reset
        @events = []
      end

      def record(event)
        @events << event
      end

      def events
        @events
      end
    end

    class Current
      THREAD_KEY = :upkeep_current_user

      class << self
        def set(user:)
          previous = Thread.current[THREAD_KEY]
          Thread.current[THREAD_KEY] = user
          yield
        ensure
          Thread.current[THREAD_KEY] = previous
        end

        def user
          user = Thread.current[THREAD_KEY]
          dependency = Dependencies::Identity.new(
            source: "Current.user",
            key: "id",
            value: user&.id,
            metadata: {
              table: user&.class&.table_name,
              id: user&.id
            }
          )

          Observation.record_dependency(dependency, event: {
            type: "identity_read",
            source: "Current.user",
            key: "id",
            value: user&.id,
            table: user&.class&.table_name,
            id: user&.id
          })
          user
        end
      end
    end

    module AttributeObserver
      def _read_attribute(attr_name, &block)
        value = super

        dependency = Dependencies::ActiveRecordAttribute.new(
          table: self.class.table_name,
          model: self.class.name,
          id: primary_key_value(attr_name, value),
          attribute: attr_name.to_s
        )

        Observation.record_dependency(dependency, event: {
          type: "attribute_read",
          table: self.class.table_name,
          model: self.class.name,
          id: primary_key_value(attr_name, value),
          attribute: attr_name.to_s
        })

        value
      end

      private

      def primary_key_value(attr_name, value)
        primary_key = self.class.primary_key
        return nil unless primary_key
        return value if attr_name.to_s == primary_key.to_s

        @attributes.fetch_value(primary_key)
      rescue StandardError
        nil
      end
    end

    module AssociationObserver
      def load_target
        Observation.record({
          type: "association_load",
          owner_table: owner.class.table_name,
          owner_id: owner.id,
          association: reflection.name.to_s,
          target_table: reflection.klass.table_name
        })

        super
      end
    end

    module RelationObserver
      def update_all(updates)
        ChangeLog.record({
          type: "bulk_update",
          table: klass.table_name,
          changed_attributes: update_columns(updates),
          predicate_sql: safe_sql,
          predicate_columns: Observation.columns_from_sql(safe_sql)
        })

        super
      end

      def delete_all
        ChangeLog.record({
          type: "bulk_delete",
          table: klass.table_name,
          changed_attributes: [klass.primary_key].compact,
          predicate_sql: safe_sql,
          predicate_columns: Observation.columns_from_sql(safe_sql)
        })

        super
      end

      private

      def safe_sql
        to_sql
      rescue StandardError => error
        "#{error.class}: #{error.message}"
      end

      def update_columns(updates)
        case updates
        when Hash
          updates.keys.map(&:to_s)
        else
          updates.to_s.scan(/\b([a-z_][a-zA-Z0-9_]*)\s*=/).flatten.uniq
        end
      end
    end

    module Install
      module_function

      def call
        return if @installed

        ActiveRecord::AttributeMethods::Read.prepend(AttributeObserver)
        ActiveRecord::Associations::Association.prepend(AssociationObserver)
        ActiveRecord::Associations::CollectionAssociation.prepend(AssociationObserver)
        ActiveRecord::Associations::SingularAssociation.prepend(AssociationObserver)
        ActiveRecord::Relation.prepend(RelationObserver)

        ActiveRecord::Base.after_commit do |record|
          ChangeLog.record({
            type: record.previous_changes.key?("id") ? "create_or_update" : "update",
            table: record.class.table_name,
            model: record.class.name,
            id: record.id,
            changed_attributes: record.previous_changes.keys.map(&:to_s).sort
          })
        end

        @installed = true
      end
    end
  end
end
