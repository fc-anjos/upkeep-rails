# frozen_string_literal: true

require "test_helper"

class SharedStreamsViewer
  attr_reader :id

  def initialize(id)
    @id = id
  end
end

class SharedStreamsTest < Minitest::Test
  def test_render_site_with_host_read_is_public_and_yields_shared_stream
    recorder = recorder_with([host_dependency("one.example.test")])
    names = Upkeep::SharedStreams.names_for_recorder(recorder)

    assert_equal "public", Upkeep::SharedStreams.identity_signature_for(recorder.graph, "site:cards/list")
    assert_equal 1, names.size
    assert_match(/\Aupkeep:shared:/, names.first)
  end

  def test_same_host_fingerprint_yields_the_same_stream_name
    first = Upkeep::SharedStreams.names_for_recorder(recorder_with([host_dependency("one.example.test")]))
    second = Upkeep::SharedStreams.names_for_recorder(recorder_with([host_dependency("one.example.test")]))

    refute_empty first
    assert_equal first, second
  end

  def test_different_host_fingerprints_yield_different_stream_names
    first = Upkeep::SharedStreams.names_for_recorder(recorder_with([host_dependency("one.example.test")]))
    second = Upkeep::SharedStreams.names_for_recorder(recorder_with([host_dependency("two.example.test")]))

    refute_empty first
    refute_empty second
    assert_empty first & second
  end

  def test_host_read_changes_stream_name_against_host_free_frame
    host_free = Upkeep::SharedStreams.names_for_recorder(recorder_with([]))
    hosted = Upkeep::SharedStreams.names_for_recorder(recorder_with([host_dependency("one.example.test")]))

    refute_empty host_free
    refute_empty hosted
    assert_empty host_free & hosted
  end

  def test_session_partitioned_render_site_yields_no_shared_stream
    recorder = recorder_with([
      host_dependency("one.example.test"),
      Upkeep::Dependencies::SessionValue.new(key: :viewer, value: "Alice")
    ])

    refute_equal "public", Upkeep::SharedStreams.identity_signature_for(recorder.graph, "site:cards/list")
    assert_empty Upkeep::SharedStreams.names_for_recorder(recorder)
  end

  def test_partitioning_classification_for_identity_sources
    assert Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::SessionValue.new(key: :viewer, value: "Alice"))
    assert Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::CookieValue.new(key: :viewer, value: "Alice"))
    assert Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::WardenUser.new(scope: :user, user: SharedStreamsViewer.new(7)))
    assert Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::RequestValue.new(key: :remote_ip, value: "203.0.113.7"))
    assert Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::RequestValue.new(key: :user_agent, value: "UpkeepBrowser"))
    assert Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::RequestValue.new(key: :subdomain, value: "tenant"))
    refute Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::RequestValue.new(key: :host, value: "one.example.test"))
    refute Upkeep::Dependencies.partitioning_identity?(Upkeep::Dependencies::RequestValue.new(key: :request_method, value: "GET"))
  end

  def test_deployment_stable_classification_survives_persistence_round_trip
    restored = Upkeep::Dependencies.from_h(host_dependency("one.example.test").to_h)

    assert Upkeep::Dependencies.deployment_stable_request?(restored)
    refute Upkeep::Dependencies.partitioning_identity?(restored)
    refute Upkeep::Dependencies.deployment_stable_request?(
      Upkeep::Dependencies.from_h(Upkeep::Dependencies::RequestValue.new(key: :remote_ip, value: "203.0.113.7").to_h)
    )
  end

  private

  def recorder_with(dependencies, recipe: recipe_stub)
    recorder = Upkeep::Runtime::Recorder.new
    recorder.with_frame("site:cards/list", kind: "render_site", site_id: "cards/list", recipe: recipe) do
      dependencies.each { |dependency| recorder.record_dependency(dependency) }
    end
    recorder
  end

  def host_dependency(host)
    Upkeep::Dependencies::RequestValue.new(key: :host, value: host)
  end

  def recipe_stub
    recipe = Object.new
    recipe.define_singleton_method(:to_h) { { kind: "render_site", template: "cards/list" } }
    recipe
  end
end
