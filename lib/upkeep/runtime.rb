# frozen_string_literal: true

require "active_record"
require "active_support/current_attributes"
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

      attr_reader :graph

      def initialize(graph: nil)
        @frame_stack = []
        @graph = graph || DAG::Graph.new
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

      def drain
        events = @events
        @events = []
        events
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

        install_current_attributes_observer
        install_warden_observer
        install_action_dispatch_observers

        ActiveRecord::AttributeMethods::Read.prepend(AttributeObserver)
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
