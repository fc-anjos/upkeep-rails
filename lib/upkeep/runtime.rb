# frozen_string_literal: true

require "active_record"
require "active_support/current_attributes"
require "digest"
require_relative "active_record_query"

module Upkeep
  module Runtime
    module Observation
      THREAD_KEY = :upkeep_recorder

      module_function

      def capture_request
        previous = Thread.current[THREAD_KEY]
        recorder = Recorder.new
        Thread.current[THREAD_KEY] = recorder

        result = yield(recorder)
        [result, recorder]
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      def capture_frame(frame_id, metadata = {})
        recorder = Thread.current[THREAD_KEY]
        return yield unless recorder

        recorder.with_frame(frame_id, metadata) { yield }
      end

      def record_dependency(dependency)
        Thread.current[THREAD_KEY]&.record_dependency(dependency)
      end

      def refuse_boundary(boundary)
        Thread.current[THREAD_KEY]&.refuse_boundary(**boundary)
      end

      def recorder
        Thread.current[THREAD_KEY]
      end

    end

    class Recorder
      REQUEST_NODE_ID = :request
      RefusedBoundary = Data.define(:reason, :message, :suggestions, :source)

      attr_reader :graph, :refused_boundaries

      def initialize(graph: nil)
        @frame_stack = []
        @graph = graph || DAG::Graph.new
        @refused_boundaries = []
        @graph.add_node(REQUEST_NODE_ID, kind: :request, payload: {}) unless @graph.node?(REQUEST_NODE_ID)
      end

      def self.from_h(snapshot)
        snapshot = Dependencies.symbolize_keys(snapshot)
        new(graph: DAG::Graph.from_h(snapshot.fetch(:graph)))
      end

      def to_h
        { graph: graph.to_h }
      end

      def with_frame(frame_id, metadata)
        @graph.add_node(frame_id, kind: :frame, payload: metadata)
        @graph.add_edge(current_owner, frame_id, reason: :contains)
        @frame_stack.push(frame_id)
        yield
      ensure
        @frame_stack.pop
      end

      def record_dependency(dependency)
        @graph.add_dependency(current_owner, dependency)
      end

      def refuse_boundary(reason:, message:, suggestions:, source:)
        boundary = RefusedBoundary.new(
          reason.to_s,
          message.to_s,
          Array(suggestions).map(&:to_s),
          source.to_s
        )
        return false if @refused_boundaries.include?(boundary)

        @refused_boundaries << boundary
        true
      end

      def reactive?
        @refused_boundaries.empty?
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
      THREAD_KEY = :upkeep_change_log_events
      @events = []
      @mutex = Mutex.new

      module_function

      def reset
        @mutex.synchronize { @events = [] }
        Thread.current[THREAD_KEY] = nil
      end

      def record(event)
        if (events = Thread.current[THREAD_KEY])
          events << event
        else
          @mutex.synchronize { @events << event }
        end
      end

      def events
        if (events = Thread.current[THREAD_KEY])
          events
        else
          @mutex.synchronize { @events.dup }
        end
      end

      def drain
        if (events = Thread.current[THREAD_KEY])
          drained = events.dup
          events.clear
          drained
        else
          @mutex.synchronize do
            events = @events
            @events = []
            events
          end
        end
      end

      def capture
        previous = Thread.current[THREAD_KEY]
        events = []
        Thread.current[THREAD_KEY] = events

        [yield, events.dup]
      ensure
        Thread.current[THREAD_KEY] = previous
      end
    end

    module ChangeEvents
      module_function

      def active_record_commit(record)
        return active_record_destroy(record) if record.destroyed?

        attribute_changes = previous_changes(record.previous_changes)

        {
          type: created_record?(record, attribute_changes) ? "create" : "update",
          table: record.class.table_name,
          model: record.class.name,
          id: record.id,
          changed_attributes: attribute_changes.keys.sort,
          old_values: attribute_changes.transform_values { |change| change.fetch(:old) },
          new_values: attribute_changes.transform_values { |change| change.fetch(:new) },
          attribute_changes: attribute_changes
        }
      end

      def active_record_destroy(record)
        old_values = record.attributes.transform_keys(&:to_s)

        {
          type: "destroy",
          table: record.class.table_name,
          model: record.class.name,
          id: record.id,
          changed_attributes: old_values.keys.sort,
          old_values: old_values,
          new_values: {},
          attribute_changes: old_values.transform_values { |value| { old: value, new: nil } }
        }
      end

      def active_record_update_columns(record, changed_attributes:, new_values: {})
        changed_attributes = Array(changed_attributes).map(&:to_s).sort
        new_values = new_values.transform_keys(&:to_s)

        {
          type: "update",
          table: record.class.table_name,
          model: record.class.name,
          id: record.class.primary_key && record.public_send(record.class.primary_key),
          changed_attributes: changed_attributes,
          old_values: {},
          new_values: new_values,
          attribute_changes: changed_attributes.to_h do |attribute|
            [attribute, { old: nil, new: new_values[attribute] }]
          end
        }
      end

      def bulk_update(table:, model:, changed_attributes:, predicate_sql:, predicate_coverage:, predicate_table_columns:, new_values: {})
        changed_attributes = Array(changed_attributes).map(&:to_s).sort
        new_values = new_values.transform_keys(&:to_s)

        {
          type: "bulk_update",
          table: table,
          model: model,
          changed_attributes: changed_attributes,
          old_values: {},
          new_values: new_values,
          attribute_changes: changed_attributes.to_h do |attribute|
            [attribute, { old: nil, new: new_values[attribute] }]
          end,
          predicate_sql: predicate_sql,
          predicate_coverage: predicate_coverage,
          predicate_table_columns: predicate_table_columns
        }
      end

      def bulk_delete(table:, model:, changed_attributes:, predicate_sql:, predicate_coverage:, predicate_table_columns:)
        changed_attributes = Array(changed_attributes).map(&:to_s).sort

        {
          type: "bulk_delete",
          table: table,
          model: model,
          changed_attributes: changed_attributes,
          old_values: {},
          new_values: {},
          attribute_changes: changed_attributes.to_h { |attribute| [attribute, { old: nil, new: nil }] },
          predicate_sql: predicate_sql,
          predicate_coverage: predicate_coverage,
          predicate_table_columns: predicate_table_columns
        }
      end

      def previous_changes(changes)
        changes.to_h.transform_keys(&:to_s).transform_values do |(old_value, new_value)|
          { old: old_value, new: new_value }
        end
      end

      def created_record?(record, attribute_changes)
        primary_key = record.class.primary_key
        return false unless primary_key

        primary_key_change = attribute_changes[primary_key.to_s]
        primary_key_change && primary_key_change.fetch(:old).nil? && !primary_key_change.fetch(:new).nil?
      end
    end

    module Ambient
      module_function

      def record_current_attribute(owner, name, value)
        dependency = Dependencies::CurrentAttribute.new(owner: owner, name: name, value: value)
        Observation.record_dependency(dependency)
      end

      def record_session(key, value)
        dependency = Dependencies::SessionValue.new(key: key, value: value)
        Observation.record_dependency(dependency)
      end

      def record_cookie(key, value)
        dependency = Dependencies::CookieValue.new(key: key, value: value)
        Observation.record_dependency(dependency)
      end

      def record_request(key, value)
        dependency = Dependencies::RequestValue.new(key: key, value: value)
        Observation.record_dependency(dependency)
      end

      def record_warden_user(scope, user)
        dependency = Dependencies::WardenUser.new(scope: scope, user: user)
        Observation.record_dependency(dependency)
      end
    end

    class ObservedHash
      def initialize(source:, values:)
        @source = source
        @values = values || {}
      end

      def [](key)
        value = lookup(key)
        record(key, value)
        value
      end

      def fetch(key, *fallback)
        if include_key?(key)
          self[key]
        elsif block_given?
          yield key
        elsif fallback.any?
          fallback.first
        else
          @values.fetch(key)
        end
      end

      def dig(first_key, *rest)
        value = self[first_key]
        rest.empty? || value.nil? ? value : value.dig(*rest)
      end

      private

      def lookup(key)
        return @values[key] if @values.key?(key)
        return @values[key.to_s] if @values.key?(key.to_s)
        return @values[key.to_sym] if key.respond_to?(:to_sym) && @values.key?(key.to_sym)

        nil
      end

      def include_key?(key)
        @values.key?(key) ||
          @values.key?(key.to_s) ||
          (key.respond_to?(:to_sym) && @values.key?(key.to_sym))
      end

      def record(key, value)
        case @source
        when :session
          Ambient.record_session(key, value)
        when :cookie
          Ambient.record_cookie(key, value)
        end
      end
    end

    class ObservedRequest
      def initialize(values)
        @values = values || {}
      end

      def host = read(:host)

      def subdomain = read(:subdomain)

      def path = read(:path)

      def fullpath = read(:fullpath)

      def request_method = read(:request_method)

      def user_agent = read(:user_agent)

      def remote_ip = read(:remote_ip)

      def params = read(:params)

      def [](key)
        read(key)
      end

      private

      def read(key)
        value = lookup(key)
        Ambient.record_request(key, value)
        value
      end

      def lookup(key)
        return @values[key] if @values.key?(key)
        return @values[key.to_s] if @values.key?(key.to_s)
        return @values[key.to_sym] if key.respond_to?(:to_sym) && @values.key?(key.to_sym)

        nil
      end
    end

    class ObservedWarden
      def initialize(users_by_scope)
        @users_by_scope = users_by_scope || {}
      end

      def user(scope = :user, **options)
        scope = options.fetch(:scope, scope)
        value = @users_by_scope[scope] || @users_by_scope[scope.to_s] || @users_by_scope[scope.to_sym]
        Ambient.record_warden_user(scope, value)
        value
      end

      def authenticate(*args, **options)
        user(extract_scope(args, options))
      end

      def authenticated?(*args, **options)
        !user(extract_scope(args, options)).nil?
      end

      private

      def extract_scope(args, options)
        options.fetch(:scope) { args.first || :user }
      end
    end

    module CurrentAttributesClassObserver
      def attribute(*names, **options)
        result = super
        Runtime.wrap_current_attribute_readers(self, names)
        result
      end
    end

    module WardenObserver
      def user(*args, **options, &block)
        value = super
        Runtime::Ambient.record_warden_user(warden_scope(args, options), value)
        value
      end

      def authenticate(*args, **options, &block)
        value = super
        Runtime::Ambient.record_warden_user(warden_scope(args, options), value)
        value
      end

      private

      def warden_scope(args, options)
        options.fetch(:scope) { args.first || :user }
      end
    end

    module SessionObserver
      def [](key)
        value = super
        Runtime::Ambient.record_session(key, value)
        value
      end

      def fetch(key, *args, &block)
        value = super
        Runtime::Ambient.record_session(key, value)
        value
      end
    end

    module CookieObserver
      def [](key)
        value = super
        Runtime::Ambient.record_cookie(key, value)
        value
      end
    end

    module RequestObserver
      def host
        value = super
        Runtime::Ambient.record_request(:host, value)
        value
      end

      def subdomain
        value = super
        Runtime::Ambient.record_request(:subdomain, value)
        value
      end

      def path
        value = super
        Runtime::Ambient.record_request(:path, value)
        value
      end

      def fullpath
        value = super
        Runtime::Ambient.record_request(:fullpath, value)
        value
      end

      def request_method
        value = super
        Runtime::Ambient.record_request(:request_method, value)
        value
      end

      def user_agent
        value = super
        Runtime::Ambient.record_request(:user_agent, value)
        value
      end

      def remote_ip
        value = super
        Runtime::Ambient.record_request(:remote_ip, value)
        value
      end

      def params
        value = super
        Runtime::Ambient.record_request(:params, value)
        value
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
              model: user&.class&.name,
              table: user&.class&.table_name,
              id: user&.id
            }.compact
          )

          Observation.record_dependency(dependency)
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

        Observation.record_dependency(dependency)

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

    module PersistenceObserver
      def update_columns(attributes)
        new_values = upkeep_update_column_values(attributes)
        changed_attributes = new_values.keys

        super.tap do |result|
          if result
            ChangeLog.record(
              ChangeEvents.active_record_update_columns(
                self,
                changed_attributes: changed_attributes,
                new_values: new_values
              )
            )
          end
        end
      end

      private

      def upkeep_update_column_values(attributes)
        attributes.to_h.reject { |attribute, _value| attribute.to_s == "touch" }.transform_keys do |attribute|
          self.class.attribute_aliases.fetch(attribute.to_s, attribute.to_s)
        end
      end
    end

    module RelationObserver
      SUPPRESS_DEPENDENCY_KEY = :upkeep_runtime_relation_dependency_suppressed

      def self.suppress_dependency_tracking
        previous = Thread.current[SUPPRESS_DEPENDENCY_KEY]
        Thread.current[SUPPRESS_DEPENDENCY_KEY] = true
        yield
      ensure
        Thread.current[SUPPRESS_DEPENDENCY_KEY] = previous
      end

      def self.dependency_tracking_suppressed?
        Thread.current[SUPPRESS_DEPENDENCY_KEY]
      end

      def exec_queries(...)
        record_collection_dependency
        super
      end

      def pluck(...)
        record_collection_dependency
        super
      end

      def update_all(updates)
        analysis = ActiveRecordQuery.analyze(self, opaque_table_policy: :allow_table)
        event = ChangeEvents.bulk_update(
          table: klass.table_name,
          model: klass.name,
          changed_attributes: update_columns(updates),
          predicate_sql: analysis.sql,
          predicate_coverage: analysis.coverage.to_s,
          predicate_table_columns: analysis.table_columns,
          new_values: update_values(updates)
        )

        super.tap { ChangeLog.record(event) }
      end

      def delete_all
        analysis = ActiveRecordQuery.analyze(self, opaque_table_policy: :allow_table)
        event = ChangeEvents.bulk_delete(
          table: klass.table_name,
          model: klass.name,
          changed_attributes: [klass.primary_key].compact,
          predicate_sql: analysis.sql,
          predicate_coverage: analysis.coverage.to_s,
          predicate_table_columns: analysis.table_columns
        )

        super.tap { ChangeLog.record(event) }
      end

      private

      def record_collection_dependency
        return unless Observation.recorder
        return if RelationObserver.dependency_tracking_suppressed?

        analysis = ActiveRecordQuery.analyze(self)
        Observation.record_dependency(
          Dependencies::ActiveRecordCollection.new(
            primary_table: analysis.primary_table,
            table_columns: analysis.table_columns,
            coverage: analysis.coverage,
            sql: analysis.sql,
            predicates: analysis.predicates
          )
        )
      rescue ActiveRecordQuery::OpaqueRelationError
        nil
      end

      def update_columns(updates)
        case updates
        when Hash
          updates.keys.map(&:to_s)
        else
          klass.column_names
        end
      end

      def update_values(updates)
        return {} unless updates.is_a?(Hash)

        updates.transform_keys(&:to_s)
      end
    end

    module Install
      module_function

      def call
        return if @installed

        install_current_attributes_observer
        install_warden_observer
        install_action_dispatch_observers

        ActiveRecord::AttributeMethods::Read.prepend(AttributeObserver)
        ActiveRecord::Base.prepend(PersistenceObserver) unless ActiveRecord::Base < PersistenceObserver
        ActiveRecord::Relation.prepend(RelationObserver)

        ActiveRecord::Base.after_commit do |record|
          ChangeLog.record(ChangeEvents.active_record_commit(record))
        end

        @installed = true
      end

      def install_current_attributes_observer
        singleton = class << ActiveSupport::CurrentAttributes; self; end
        singleton.prepend(CurrentAttributesClassObserver) unless singleton < CurrentAttributesClassObserver

        ObjectSpace.each_object(Class) do |klass|
          next unless klass < ActiveSupport::CurrentAttributes

          Runtime.wrap_current_attribute_readers(klass, current_attribute_names(klass))
        end
      end

      def install_warden_observer
        return unless defined?(::Warden::Proxy)
        return if ::Warden::Proxy < WardenObserver

        ::Warden::Proxy.prepend(WardenObserver)
      end

      def install_action_dispatch_observers
        if defined?(::ActionDispatch::Request::Session) && !(::ActionDispatch::Request::Session < SessionObserver)
          ::ActionDispatch::Request::Session.prepend(SessionObserver)
        end

        if defined?(::ActionDispatch::Cookies::CookieJar) && !(::ActionDispatch::Cookies::CookieJar < CookieObserver)
          ::ActionDispatch::Cookies::CookieJar.prepend(CookieObserver)
        end

        if defined?(::ActionDispatch::Request) && !(::ActionDispatch::Request < RequestObserver)
          ::ActionDispatch::Request.prepend(RequestObserver)
        end
      end

      def current_attribute_names(klass)
        if klass.respond_to?(:defaults)
          klass.defaults.keys
        else
          []
        end
      end
    end

    module_function

    def wrap_current_attribute_readers(klass, names)
      wrapped = klass.instance_variable_get(:@upkeep_wrapped_current_attributes) || {}

      names.each do |name|
        name = name.to_sym
        next if wrapped[name]
        next unless klass.method_defined?(name)

        original_reader = klass.instance_method(name)
        klass.define_method(name) do
          value = original_reader.bind_call(self)
          Runtime::Ambient.record_current_attribute(klass.name || klass.inspect, name, value)
          value
        end
        wrapped[name] = true
      end

      klass.instance_variable_set(:@upkeep_wrapped_current_attributes, wrapped)
    end
  end
end
