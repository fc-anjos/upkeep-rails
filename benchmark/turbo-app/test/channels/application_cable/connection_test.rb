# frozen_string_literal: true

require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection

  setup do
    @previous_bench = ENV["BENCH"]
    ENV["BENCH"] = "1"
    @user = User.create!(name: "alice", email: "alice@example.com", password: "secret123")
  end

  teardown do
    User.delete_all
    ENV["BENCH"] = @previous_bench
  end

  test "connect emits a bench cable connect notification" do
    cookies.signed[:user_id] = @user.id
    events = []
    subscription = ActiveSupport::Notifications.subscribe("bench.cable_connect") { |event| events << event }

    connect params: { bench_connect_id: "connect-turbo-1" }

    assert_equal @user, connection.current_user

    event = events.last
    assert_equal "connect-turbo-1", event&.payload&.dig(:bench_connect_id)
    assert_equal ApplicationCable::Connection.name, event&.payload&.dig(:connection_class)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "bench install prepends the cable open hook" do
    BenchMetrics.install

    assert_includes ActionCable::Server::Base.ancestors, BenchMetrics::ActionCableServerCallInstrumentation
    assert_includes ActionCable::Connection::Base.ancestors, BenchMetrics::ActionCableConnectionHandleOpenInstrumentation
  end

  test "server call instrumentation emits a bench cable request notification" do
    env = Rack::MockRequest.env_for(
      "/cable?bench_connect_id=request-turbo-1",
      "REQUEST_METHOD" => "GET",
      "action_dispatch.request_id" => "req-turbo-request"
    )
    server = ActionCable::Server::Base.new

    events = []
    subscription = ActiveSupport::Notifications.subscribe("bench.cable_request") { |event| events << event }

    result = BenchMetrics.instrument_cable_request(server, env) { :ok }

    assert_equal :ok, result

    event = events.last
    assert_equal "request-turbo-1", event&.payload&.dig(:bench_connect_id)
    assert_equal ActionCable::Server::Base.name, event&.payload&.dig(:server_class)
    assert_equal "req-turbo-request", event&.payload&.dig(:request_id)
    assert_equal "GET", event&.payload&.dig(:method)
    assert_equal "/cable?bench_connect_id=request-turbo-1", event&.payload&.dig(:path)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "handle open instrumentation emits a bench cable open notification" do
    request = Struct.new(:params, :request_id, :fullpath).new(
      { "bench_connect_id" => "open-turbo-1" },
      "req-turbo-open",
      "/cable?bench_connect_id=open-turbo-1"
    )
    connection = Class.new do
      def initialize(request)
        @request = request
      end

      private

      attr_reader :request
    end.new(request)

    events = []
    subscription = ActiveSupport::Notifications.subscribe("bench.cable_open") { |event| events << event }

    result = BenchMetrics.instrument_cable_open(connection, request) { :ok }

    assert_equal :ok, result

    event = events.last
    assert_equal "open-turbo-1", event&.payload&.dig(:bench_connect_id)
    assert_equal "req-turbo-open", event&.payload&.dig(:request_id)
    assert_equal "/cable?bench_connect_id=open-turbo-1", event&.payload&.dig(:path)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end
