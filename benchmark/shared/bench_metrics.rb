# frozen_string_literal: true

# Shared benchmark instrumentation and metrics endpoint for both apps.
#
# Usage from config/initializers/benchmark_instrumentation.rb:
#   require_relative "../../shared/bench_metrics"
#   BenchMetrics.install
#
# Usage from config/routes.rb:
#   mount BenchMetrics::Endpoint, at: "/bench/metrics" if BenchMetrics.enabled?

require "json"

module BenchMetrics
  UPKEEP_RENDER_REQUEST = "upkeep.render_request"
  UPKEEP_RENDER_PAGE_REPLAY = "upkeep.render_page_replay"
  UPKEEP_RENDER_REGION_OUTCOME = "upkeep.render_region.outcome"
  UPKEEP_SUBSCRIBE_AND_INJECT = "upkeep.subscribe_and_inject"
  UPKEEP_SUBSCRIPTION_REGISTER = "upkeep.subscription_register"
  UPKEEP_SUBSCRIPTION_ATTACH = "upkeep.subscription_attach"
  UPKEEP_SUBSCRIPTION_STORE_FIND_OR_CREATE = "upkeep.subscription_store_find_or_create"
  UPKEEP_SUBSCRIPTION_STORE_CREATE_ENDPOINT = "upkeep.subscription_store_create_endpoint"
  UPKEEP_SUBSCRIPTION_STORE_REGISTER = "register_subscription_store.upkeep"
  UPKEEP_SUBSCRIPTION_INDEX_LOOKUP = "lookup_subscription_index.upkeep"
  UPKEEP_BROKER_REQUEST = "upkeep.broker_request"
  UPKEEP_BROKER_SERVER_REQUEST = "upkeep.broker_server_request"
  UPKEEP_PLAN = "plan.upkeep"
  UPKEEP_BUILD_TURBO_STREAMS = "build_turbo_streams.upkeep"
  UPKEEP_REFUSED_BOUNDARY = "refused_boundary.upkeep"
  UPKEEP_RELAY_PUBLISH = "upkeep.relay_publish"
  UPKEEP_PUBLISHER_DRAIN_STARTED = "upkeep.publisher_drain_started"
  UPKEEP_MEMORY_SNAPSHOT = "upkeep.memory_snapshot"
  UPKEEP_INVALIDATION = "upkeep.invalidation"
  AMBIENT_REPLAY_SOURCES = %w[session cookie request].freeze

  def self.enabled?
    ENV["BENCH"] == "1"
  end

  def self.install
    return unless enabled?
    return if @installed

    require "objspace"

    setup_log_file
    setup_counters
    subscribe_notifications
    install_action_cable_hooks
    start_memory_sampler
    install_endpoint
    start_allocation_trace! if ENV["BENCH_ALLOC_TRACE"] == "1"

    @installed = true
    Rails.logger.info "[Benchmark] Instrumentation active -> #{@log_file}"
  end

  # M4: opt-in allocation-site sampling. Names the file:line that
  # allocates the dominant retained classes the M2 deep walk surfaces.
  # `ObjectSpace.trace_object_allocations_*` carries per-allocation
  # overhead, so it stays off by default and gates on BENCH_ALLOC_TRACE.
  def self.start_allocation_trace!
    ObjectSpace.trace_object_allocations_start
  end

  ALLOCATION_SITE_TOP_N = 30

  # For the top-N classes by retained bytes (M2 output), sample up to
  # 1,000 instances each and aggregate by allocation file:line. Returns
  # a Hash of "ClassName" => [{ site:, count: }, ...] sorted by count
  # desc per class.
  def self.allocation_sites
    return {} unless ENV["BENCH_ALLOC_TRACE"] == "1"
    return {} unless ObjectSpace.respond_to?(:allocation_sourcefile)

    sites_by_class = {}
    [ String, Hash, Array ].each do |klass|
      counts = Hash.new(0)
      sampled = 0
      ObjectSpace.each_object(klass) do |obj|
        break if sampled >= 1_000
        file = ObjectSpace.allocation_sourcefile(obj)
        next unless file
        line = ObjectSpace.allocation_sourceline(obj)
        counts["#{shorten_path(file)}:#{line}"] += 1
        sampled += 1
      rescue StandardError
        next
      end

      next if counts.empty?
      sites_by_class[klass.name] = counts
        .sort_by { |_, v| -v }
        .first(ALLOCATION_SITE_TOP_N)
        .each_with_object({}) { |(site, count), out| out[site] = count }
    end
    sites_by_class
  rescue StandardError
    {}
  end

  ALLOCATION_PATH_ROOTS = [ Dir.pwd + "/", "/" ].freeze

  def self.shorten_path(path)
    ALLOCATION_PATH_ROOTS.each do |root|
      return path[root.length..] if path.start_with?(root)
    end
    path
  end

  def self.instrument_controller_request(controller)
    return yield unless enabled?

    request = controller.request
    controller.response.set_header("X-Bench-Request-Id", request.request_id)

    ActiveSupport::Notifications.instrument(
      "bench.request",
      phase: "#{controller.controller_name}##{controller.action_name}",
      request_id: request.request_id,
      controller: controller.class.name,
      action: controller.action_name,
      method: request.request_method,
      path: request.fullpath
    ) do
      yield
    end
  end

  def self.instrument_cable_connect(connection)
    return yield unless enabled?

    request = action_dispatch_request(connection.env)
    params = request_params_hash(request&.params)

    ActiveSupport::Notifications.instrument(
      "bench.cable_connect",
      bench_connect_id: params["bench_connect_id"],
      connection_class: connection.class.name,
      request_id: request&.request_id,
      path: request_fullpath(request)
    ) do
      yield
    end
  end

  def self.instrument_cable_request(server, env)
    return yield unless enabled?

    request = action_dispatch_request(env)
    params = request_params_hash(request&.params)

    ActiveSupport::Notifications.instrument(
      "bench.cable_request",
      bench_connect_id: params["bench_connect_id"],
      server_class: server.class.name,
      request_id: request&.request_id,
      method: env["REQUEST_METHOD"],
      path: request_fullpath(request)
    ) do
      yield
    end
  end

  def self.instrument_cable_handle_open(connection)
    return yield unless enabled?
    instrument_cable_open(connection, action_dispatch_request(connection.env)) { yield }
  end

  def self.instrument_cable_open(connection, request)
    return yield unless enabled?

    params = request_params_hash(request&.params)

    ActiveSupport::Notifications.instrument(
      "bench.cable_open",
      bench_connect_id: params["bench_connect_id"],
      connection_class: connection.class.name,
      request_id: request&.request_id,
      path: request_fullpath(request)
    ) do
      yield
    end
  end

  def self.instrument_action_cable_subscription(channel)
    return yield unless enabled?

    params = request_params_hash(channel.respond_to?(:params) ? channel.params : {})
    request = action_dispatch_request(channel.connection&.env)

    ActiveSupport::Notifications.instrument(
      "bench.subscription_registration",
      bench_connect_id: params["bench_connect_id"],
      channel_class: channel.class.name,
      identifier: channel.identifier,
      request_id: request&.request_id,
      path: request_fullpath(request)
    ) do
      yield
    end
  end

  # ── Counters (atomically updated, read by the metrics endpoint) ──────

  @render_count = Concurrent::AtomicFixnum.new(0)
  @invalidation_count = Concurrent::AtomicFixnum.new(0)
  @broadcast_count = Concurrent::AtomicFixnum.new(0)
  @transmit_count = Concurrent::AtomicFixnum.new(0)
  @last_rss_kb = Concurrent::AtomicFixnum.new(0)
  @plan_count = Concurrent::AtomicFixnum.new(0)
  @planned_target_count = Concurrent::AtomicFixnum.new(0)
  @turbo_stream_batch_count = Concurrent::AtomicFixnum.new(0)
  @turbo_stream_group_count = Concurrent::AtomicFixnum.new(0)
  @turbo_stream_render_count = Concurrent::AtomicFixnum.new(0)
  @turbo_stream_payload_bytes = Concurrent::AtomicFixnum.new(0)
  @reactivity_mutex = Mutex.new
  @refused_boundaries_by_reason = Hash.new(0)
  @live_deoptimizations_by_reason = Hash.new(0)
  @turbo_stream_actions = Hash.new(0)

  class << self
    attr_reader :render_count, :invalidation_count, :broadcast_count, :transmit_count, :last_rss_kb
  end

  def self.snapshot
    rss_kb = @last_rss_kb.value
    gc = GC.stat

    {
      rss_mb: (rss_kb / 1024.0).round(1),
      gc: {
        heap_live_slots: gc[:heap_live_slots],
        total_allocated_objects: gc[:total_allocated_objects],
        total_freed_objects: gc[:total_freed_objects],
        gc_count: gc[:count],
        major_gc_count: gc[:major_gc_count],
        total_time_ms: (GC::Profiler.enabled? ? (GC::Profiler.total_time * 1000).round(1) : nil)
      },
      counters: {
        renders: @render_count.value,
        invalidations: @invalidation_count.value,
        broadcasts: @broadcast_count.value,
        transmits: @transmit_count.value
      },
      region_outcomes: region_outcomes_snapshot,
      flags: flags_snapshot,
      diagnostics: diagnostics_snapshot,
      upkeep_reactivity: upkeep_reactivity_snapshot,
      subscription_count: subscription_count,
      timestamp: Time.now.iso8601(3)
    }
  end

  # Mechanism-level diagnostics of THIS upkeep-app worker process.
  def self.diagnostics_snapshot
    {
      pid: ::Process.pid,
      dispatch: {
        reactor_thread_alive_count: Thread.list.count { |thread|
          thread.respond_to?(:name) && thread.name == "upkeep-dispatch-reactor"
        }
      }
    }
  rescue StandardError => e
    { error: "#{e.class}: #{e.message}" }
  end

  # Expose the runtime configuration of THIS process so the bench can
  # assert the measured process matches its intent. Prevents the silent
  # "stale tier-1 answered a tier-2 bench" failure.
  def self.flags_snapshot
    cfg = Upkeep.config if defined?(Upkeep) && Upkeep.respond_to?(:config)
    {
      dispatch_ws_port: cfg ? cfg.relay_ws_port : nil,
      dispatch_metrics_port: cfg ? cfg.relay_metrics_port : nil,
      pid: ::Process.pid
    }
  rescue StandardError
    { pid: ::Process.pid }
  end

  def self.reset_counters
    @render_count = Concurrent::AtomicFixnum.new(0)
    @invalidation_count = Concurrent::AtomicFixnum.new(0)
    @broadcast_count = Concurrent::AtomicFixnum.new(0)
    @transmit_count = Concurrent::AtomicFixnum.new(0)
    @plan_count = Concurrent::AtomicFixnum.new(0)
    @planned_target_count = Concurrent::AtomicFixnum.new(0)
    @turbo_stream_batch_count = Concurrent::AtomicFixnum.new(0)
    @turbo_stream_group_count = Concurrent::AtomicFixnum.new(0)
    @turbo_stream_render_count = Concurrent::AtomicFixnum.new(0)
    @turbo_stream_payload_bytes = Concurrent::AtomicFixnum.new(0)
    setup_region_outcomes
    setup_reactivity_counters
  end

  # ── Rack endpoint ────────────────────────────────────────────────────

  Endpoint = ->(env) {
    phase = memory_phase_from_env(env)
    emit_memory_snapshot(phase: phase, force_gc: true) if phase

    body = JSON.generate(BenchMetrics.snapshot)
    [ 200, { "content-type" => "application/json" }, [ body ] ]
  }

  # ── Private ──────────────────────────────────────────────────────────

  def self.setup_log_file
    log_path = Rails.root.join("../results")
    FileUtils.mkdir_p(log_path)

    app_name = Rails.root.basename.to_s.sub("-app", "")
    @log_file = log_path.join("server-#{app_name}-#{Time.now.strftime('%Y%m%d%H%M%S')}.jsonl")
    @log = File.open(@log_file, "a")
    @log.sync = true
  end

  def self.emit(event:, duration_ms: nil, payload_bytes: nil, extra: {})
    entry = {
      event: event,
      duration_ms: duration_ms&.round(3),
      payload_bytes: payload_bytes,
      timestamp: Process.clock_gettime(Process::CLOCK_MONOTONIC).round(6),
      wall_time_ms: (Time.now.to_f * 1000).round(3)
    }.merge(extra)
    @log.puts(JSON.generate(entry))
  end

  def self.setup_counters
    GC::Profiler.enable
    setup_region_outcomes
    setup_reactivity_counters
  end

  def self.setup_region_outcomes
    @region_outcomes_mutex = Mutex.new
    @region_outcomes = Hash.new(0)
  end

  def self.subscribe_notifications
    ActiveSupport::Notifications.subscribe("render_partial.action_view") do |event|
      @render_count.increment
      emit(event: "render_partial", duration_ms: event.duration,
           extra: { template: event.payload[:identifier]&.split("/views/")&.last })
    end

    ActiveSupport::Notifications.subscribe("render_template.action_view") do |event|
      @render_count.increment
      emit(event: "render_template", duration_ms: event.duration,
           extra: { template: event.payload[:identifier]&.split("/views/")&.last })
    end

    ActiveSupport::Notifications.subscribe("transmit.action_cable") do |event|
      @transmit_count.increment
      data = event.payload[:data]
      bytes = data.is_a?(String) ? data.bytesize : JSON.generate(data).bytesize
      emit(event: "transmit", duration_ms: event.duration, payload_bytes: bytes)
    end

    ActiveSupport::Notifications.subscribe("broadcast.action_cable") do |event|
      @broadcast_count.increment
      emit(event: "broadcast", duration_ms: event.duration,
           extra: { broadcasting: event.payload[:broadcasting] })
    end

    ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
      emit(event: "process_action", duration_ms: event.duration,
           extra: { controller: event.payload[:controller], action: event.payload[:action],
                    status: event.payload[:status], method: event.payload[:method] })
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_RENDER_REQUEST) do |event|
      emit(
        event: "upkeep_render_request",
        duration_ms: event.duration,
        extra: {
          path: event.payload[:path],
          fragment_target: event.payload[:fragment_target],
          status: event.payload[:status],
          content_type: event.payload[:content_type],
          body_bytes: event.payload[:body_bytes],
          fragment_count: event.payload[:fragment_count],
          exception_class: event.payload[:exception_class],
          exception_message: event.payload[:exception_message]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_RENDER_PAGE_REPLAY) do |event|
      emit(
        event: "upkeep_render_page_replay",
        duration_ms: event.duration,
        extra: {
          path: event.payload[:path],
          status: event.payload[:status],
          content_type: event.payload[:content_type],
          body_bytes: event.payload[:body_bytes],
          fragment_count: event.payload[:fragment_count],
          build_env_ms: event.payload[:build_env_ms],
          rails_call_ms: event.payload[:rails_call_ms],
          fragment_extract_ms: event.payload[:fragment_extract_ms],
          exception_class: event.payload[:exception_class],
          exception_message: event.payload[:exception_message]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_RENDER_REGION_OUTCOME) do |event|
      increment_region_outcome(event.payload[:outcome])
      emit(
        event: "upkeep_render_region_outcome",
        duration_ms: event.duration,
        extra: {
          fragment_id: event.payload[:fragment_id],
          region_id: event.payload[:region_id],
          parent_mode: event.payload[:parent_mode],
          region_mode: event.payload[:region_mode],
          outcome: event.payload[:outcome],
          reasons: event.payload[:reasons],
          widening_policy: event.payload[:widening_policy]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_SUBSCRIPTION_ATTACH) do |event|
      emit(
        event: "upkeep_subscription_attach",
        duration_ms: event.duration,
        extra: {
          subscription_id: event.payload[:subscription_id],
          endpoint_id: event.payload[:endpoint_id],
          activate_and_fetch_ms: event.payload[:activate_and_fetch_ms],
          publish_subscribe_event_ms: event.payload[:publish_subscribe_event_ms],
          rejected: event.payload[:rejected]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_RELAY_PUBLISH) do |event|
      # Forward the publisher payload verbatim so the JSONL records
      # which fields the publisher actually set.
      emit(event: "upkeep_relay_publish", duration_ms: event.duration, extra: event.payload)
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_PUBLISHER_DRAIN_STARTED) do |event|
      emit(
        event: "upkeep_publisher_drain_started",
        duration_ms: event.duration,
        extra: {
          thread_name: event.payload[:thread_name],
          pid: event.payload[:pid],
          capacity: event.payload[:capacity]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_MEMORY_SNAPSHOT) do |event|
      emit(
        event: "upkeep_memory_snapshot",
        duration_ms: event.duration,
        extra: event.payload
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_SUBSCRIBE_AND_INJECT) do |event|
      emit(
        event: "upkeep_subscribe_and_inject",
        duration_ms: event.duration,
        extra: {
          path: event.payload[:path],
          html_bytes: event.payload[:html_bytes],
          subscription_id: event.payload[:subscription_id],
          register_ms: event.payload[:register_ms],
          build_fragment_registration_metadata_ms: event.payload[:build_fragment_registration_metadata_ms],
          inject_ms: event.payload[:inject_ms],
          fragment_registration_manifest_lookup_ms: event.payload[:fragment_registration_manifest_lookup_ms],
          fragment_registration_infer_fragment_locals_ms: event.payload[:fragment_registration_infer_fragment_locals_ms],
          fragment_registration_record_lookup_ms: event.payload[:fragment_registration_record_lookup_ms],
          fragment_registration_fragment_count: event.payload[:fragment_registration_fragment_count],
          fragment_registration_manifest_count: event.payload[:fragment_registration_manifest_count],
          fragment_registration_record_lookup_count: event.payload[:fragment_registration_record_lookup_count]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_SUBSCRIPTION_REGISTER) do |event|
      emit(
        event: "upkeep_subscription_register",
        duration_ms: event.duration,
        extra: {
          subscription_id: event.payload[:subscription_id],
          endpoint_id: event.payload[:endpoint_id],
          fragment_address: event.payload[:fragment_address],
          read_set_queries: event.payload[:read_set_queries]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_SUBSCRIPTION_STORE_FIND_OR_CREATE) do |event|
      emit(
        event: "upkeep_subscription_store_find_or_create",
        duration_ms: event.duration,
        extra: {
          subscription_id: event.payload[:subscription_id]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_SUBSCRIPTION_STORE_CREATE_ENDPOINT) do |event|
      emit(
        event: "upkeep_subscription_store_create_endpoint",
        duration_ms: event.duration,
        extra: {
          subscription_id: event.payload[:subscription_id]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_SUBSCRIPTION_STORE_REGISTER) do |event|
      emit(
        event: "upkeep_subscription_store_register",
        duration_ms: event.duration,
        extra: {
          store: event.payload[:store],
          subscription_id: event.payload[:subscription_id],
          dependency_entries: event.payload[:dependency_entries],
          index_rows: event.payload[:index_rows]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_SUBSCRIPTION_INDEX_LOOKUP) do |event|
      emit(
        event: "upkeep_subscription_index_lookup",
        duration_ms: event.duration,
        extra: {
          store: event.payload[:store],
          mode: event.payload[:mode],
          changes: event.payload[:changes],
          active_subscriptions: event.payload[:active_subscriptions],
          active_entries: event.payload[:active_entries],
          persistent_entries: event.payload[:persistent_entries]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_REFUSED_BOUNDARY) do |event|
      increment_reactivity_tally(:refused_boundaries_by_reason, event.payload[:reason])
      emit(
        event: "upkeep_refused_boundary",
        duration_ms: event.duration,
        extra: {
          reason: event.payload[:reason],
          source: event.payload[:source],
          suggestions: event.payload[:suggestions]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_PLAN) do |event|
      @plan_count.increment
      @planned_target_count.increment(event.payload[:targets].to_i)
      increment_reactivity_tally(:live_deoptimizations_by_reason, event.payload[:deoptimizations])
      emit(
        event: "upkeep_plan",
        duration_ms: event.duration,
        extra: {
          change_count: event.payload[:change_count],
          candidate_entries: event.payload[:candidate_entries],
          matched_entries: event.payload[:matched_entries],
          targets: event.payload[:targets],
          target_kinds: event.payload[:target_kinds],
          actions: event.payload[:actions],
          deoptimizations: event.payload[:deoptimizations]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_BUILD_TURBO_STREAMS) do |event|
      @turbo_stream_batch_count.increment
      @turbo_stream_group_count.increment(event.payload[:streams].to_i)
      @turbo_stream_render_count.increment(event.payload[:renders].to_i)
      @turbo_stream_payload_bytes.increment(event.payload[:payload_bytes].to_i)
      increment_reactivity_tally(:turbo_stream_actions, event.payload[:actions])
      emit(
        event: "upkeep_build_turbo_streams",
        duration_ms: event.duration,
        extra: {
          plans: event.payload[:plans],
          planned_targets: event.payload[:planned_targets],
          streams: event.payload[:streams],
          envelopes: event.payload[:envelopes],
          actions: event.payload[:actions],
          deoptimizations: event.payload[:deoptimizations],
          renders: event.payload[:renders],
          render_duration_ms: event.payload[:render_duration_ms],
          payload_bytes: event.payload[:payload_bytes]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_BROKER_REQUEST) do |event|
      emit(
        event: "upkeep_broker_request",
        duration_ms: event.duration,
        extra: {
          operation: event.payload[:operation],
          checkout_wait_ms: event.payload[:checkout_wait_ms],
          roundtrip_ms: event.payload[:roundtrip_ms]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_BROKER_SERVER_REQUEST) do |event|
      emit(
        event: "upkeep_broker_server_request",
        duration_ms: event.duration,
        extra: {
          operation: event.payload[:operation],
          queue_delay_ms: event.payload[:queue_delay_ms],
          execute_ms: event.payload[:execute_ms]
        }
      )
    end

    ActiveSupport::Notifications.subscribe("bench.request") do |event|
      emit_notification(
        notification: event,
        event: "bench_request",
        extra: {
          phase: event.payload[:phase],
          request_id: event.payload[:request_id],
          controller: event.payload[:controller],
          action: event.payload[:action],
          method: event.payload[:method],
          path: event.payload[:path]
        }
      )
    end

    ActiveSupport::Notifications.subscribe("bench.cable_connect") do |event|
      emit_notification(
        notification: event,
        event: "bench_cable_connect",
        extra: {
          bench_connect_id: event.payload[:bench_connect_id],
          connection_class: event.payload[:connection_class],
          request_id: event.payload[:request_id],
          path: event.payload[:path]
        }
      )
    end

    ActiveSupport::Notifications.subscribe("bench.cable_request") do |event|
      emit_notification(
        notification: event,
        event: "bench_cable_request",
        extra: {
          bench_connect_id: event.payload[:bench_connect_id],
          server_class: event.payload[:server_class],
          request_id: event.payload[:request_id],
          method: event.payload[:method],
          path: event.payload[:path]
        }
      )
    end

    ActiveSupport::Notifications.subscribe("bench.cable_open") do |event|
      emit_notification(
        notification: event,
        event: "bench_cable_open",
        extra: {
          bench_connect_id: event.payload[:bench_connect_id],
          connection_class: event.payload[:connection_class],
          request_id: event.payload[:request_id],
          path: event.payload[:path]
        }
      )
    end

    ActiveSupport::Notifications.subscribe("bench.subscription_registration") do |event|
      emit_notification(
        notification: event,
        event: "bench_subscription_registration",
        extra: {
          bench_connect_id: event.payload[:bench_connect_id],
          channel_class: event.payload[:channel_class],
          identifier: event.payload[:identifier],
          request_id: event.payload[:request_id],
          path: event.payload[:path]
        }
      )
    end

    ActiveSupport::Notifications.subscribe("transmit_subscription_confirmation.action_cable") do |event|
      identifier = request_params_hash(parse_json(event.payload[:identifier]))

      emit_notification(
        notification: event,
        event: "bench_subscription_confirmation",
        extra: {
          bench_connect_id: identifier["bench_connect_id"],
          channel_class: event.payload[:channel_class],
          identifier: event.payload[:identifier]
        }
      )
    end

    ActiveSupport::Notifications.subscribe(UPKEEP_INVALIDATION) do |_event|
      @invalidation_count.increment
    end
  end

  def self.sample_rss!
    rss_kb = `ps -o rss= -p #{Process.pid}`.to_i
    @last_rss_kb.value = rss_kb
    rss_kb
  end

  def self.increment_region_outcome(outcome)
    return unless outcome

    @region_outcomes_mutex ||= Mutex.new
    @region_outcomes ||= Hash.new(0)
    @region_outcomes_mutex.synchronize do
      @region_outcomes[outcome.to_s] += 1
    end
  end

  def self.region_outcomes_snapshot
    return {} unless @region_outcomes_mutex && @region_outcomes

    @region_outcomes_mutex.synchronize { @region_outcomes.dup }
  end

  def self.setup_reactivity_counters
    @reactivity_mutex ||= Mutex.new
    @reactivity_mutex.synchronize do
      @refused_boundaries_by_reason = Hash.new(0)
      @live_deoptimizations_by_reason = Hash.new(0)
      @turbo_stream_actions = Hash.new(0)
    end
  end

  def self.upkeep_reactivity_snapshot
    {
      subscription_graphs: subscription_graphs_snapshot,
      refused_boundaries: refused_boundaries_snapshot,
      delivery: upkeep_delivery_snapshot
    }
  end

  def self.subscription_graphs_snapshot
    store = current_subscription_store
    return {} unless store&.respond_to?(:subscriptions)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    subscriptions = store.subscriptions
    summary = empty_subscription_graph_summary
    summary[:subscriptions] = subscriptions.size

    subscriptions.each do |subscription|
      accumulate_subscription_graph_summary(summary, subscription)
    end

    finish_subscription_graph_summary(summary, started_at)
  rescue StandardError => e
    { error: "#{e.class}: #{e.message}" }
  end

  def self.empty_subscription_graph_summary
    {
      subscriptions: 0,
      frames: 0,
      dependencies: 0,
      replay_recipes: 0,
      replay_recipe_bytes_total: 0,
      replay_recipe_bytes_max: 0,
      shared_stream_names: 0,
      frame_kinds: Hash.new(0),
      target_kinds: Hash.new(0),
      replay_recipe_kinds: Hash.new(0),
      dependency_sources: Hash.new(0),
      ambient_replay_inputs: {
        total: 0,
        by_source: Hash.new(0)
      }
    }
  end

  def self.accumulate_subscription_graph_summary(summary, subscription)
    graph = subscription.graph
    summary[:shared_stream_names] += shared_stream_names_count(subscription)

    graph.frame_nodes.each do |frame|
      summary[:frames] += 1
      summary[:frame_kinds][frame.payload.fetch(:kind, "unknown").to_s] += 1

      recipe = frame.payload[:recipe]
      next unless recipe

      summary[:replay_recipes] += 1
      summary[:replay_recipe_kinds][recipe.kind.to_s] += 1
      summary[:target_kinds][recipe.target_kind.to_s] += 1
      bytes = replay_recipe_bytes(recipe)
      summary[:replay_recipe_bytes_total] += bytes
      summary[:replay_recipe_bytes_max] = [summary[:replay_recipe_bytes_max], bytes].max
    end

    graph.dependency_nodes.each do |dependency_node|
      source = dependency_node.payload.source.to_s
      summary[:dependencies] += 1
      summary[:dependency_sources][source] += 1

      next unless AMBIENT_REPLAY_SOURCES.include?(source)

      summary[:ambient_replay_inputs][:total] += 1
      summary[:ambient_replay_inputs][:by_source][source] += 1
    end
  end

  def self.finish_subscription_graph_summary(summary, started_at)
    summary[:frame_kinds] = sorted_hash(summary[:frame_kinds])
    summary[:target_kinds] = sorted_hash(summary[:target_kinds])
    summary[:replay_recipe_kinds] = sorted_hash(summary[:replay_recipe_kinds])
    summary[:dependency_sources] = sorted_hash(summary[:dependency_sources])
    summary[:ambient_replay_inputs] = {
      total: summary[:ambient_replay_inputs][:total],
      by_source: sorted_hash(summary[:ambient_replay_inputs][:by_source])
    }
    summary[:replay_recipe_bytes_avg] =
      if summary[:replay_recipes].positive?
        (summary[:replay_recipe_bytes_total].to_f / summary[:replay_recipes]).round(1)
      end
    summary[:collection_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(3)
    summary
  end

  def self.replay_recipe_bytes(recipe)
    JSON.generate(recipe.replay&.to_h || {}).bytesize
  rescue StandardError
    0
  end

  def self.shared_stream_names_count(subscription)
    metadata = subscription.metadata || {}
    Array(metadata["shared_stream_names"] || metadata[:shared_stream_names]).size
  end

  def self.refused_boundaries_snapshot
    by_reason = reactivity_tally_snapshot(:refused_boundaries_by_reason)
    {
      total: by_reason.values.sum,
      by_reason: by_reason
    }
  end

  def self.upkeep_delivery_snapshot
    deoptimizations = reactivity_tally_snapshot(:live_deoptimizations_by_reason)
    {
      plans: @plan_count.value,
      planned_targets: @planned_target_count.value,
      stream_batches: @turbo_stream_batch_count.value,
      render_groups: @turbo_stream_group_count.value,
      render_count: @turbo_stream_render_count.value,
      payload_bytes: @turbo_stream_payload_bytes.value,
      actions: reactivity_tally_snapshot(:turbo_stream_actions),
      live_deoptimizations: {
        total: deoptimizations.values.sum,
        by_reason: deoptimizations
      }
    }
  end

  def self.increment_reactivity_tally(name, values)
    pairs = case values
    when Hash
      values
    when nil
      {}
    else
      { values => 1 }
    end
    return if pairs.empty?

    @reactivity_mutex ||= Mutex.new
    @reactivity_mutex.synchronize do
      tally = instance_variable_get(:"@#{name}") || Hash.new(0)
      pairs.each do |key, count|
        next if key.nil?

        tally[key.to_s] += count.to_i
      end
      instance_variable_set(:"@#{name}", tally)
    end
  end

  def self.reactivity_tally_snapshot(name)
    @reactivity_mutex ||= Mutex.new
    @reactivity_mutex.synchronize do
      sorted_hash(instance_variable_get(:"@#{name}") || {})
    end
  end

  def self.sorted_hash(hash)
    hash.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
      out[key] = hash.fetch(key, hash.fetch(key.to_sym, 0)).to_i
    end
  end

  def self.install_action_cable_hooks
    return if @action_cable_hooks_requested

    if defined?(ActionCable::Server::Base)
      install_action_cable_server_hooks
    else
      ActiveSupport.on_load(:action_cable) { BenchMetrics.install_action_cable_server_hooks }
    end

    if defined?(ActionCable::Connection::Base)
      install_action_cable_connection_hooks
    else
      ActiveSupport.on_load(:action_cable_connection) { BenchMetrics.install_action_cable_connection_hooks }
    end

    if defined?(ActionCable::Channel::Base)
      install_action_cable_channel_hooks
    else
      ActiveSupport.on_load(:action_cable_channel) { BenchMetrics.install_action_cable_channel_hooks }
    end

    @action_cable_hooks_requested = true
  end

  module ActionCableServerCallInstrumentation
    def call(env)
      BenchMetrics.instrument_cable_request(self, env) { super }
    end
  end

  module ActionCableConnectionHandleOpenInstrumentation
    def handle_open
      BenchMetrics.instrument_cable_open(self, request) { super }
    end
  end

  def self.install_action_cable_server_hooks
    return if @action_cable_server_hooks_installed

    ActionCable::Server::Base.prepend(ActionCableServerCallInstrumentation)

    @action_cable_server_hooks_installed = true
  end

  def self.install_action_cable_connection_hooks
    return if @action_cable_connection_hooks_installed

    ActionCable::Connection::Base.prepend(ActionCableConnectionHandleOpenInstrumentation)

    @action_cable_connection_hooks_installed = true
  end

  def self.install_action_cable_channel_hooks
    return if @action_cable_hooks_installed

    ActionCable::Channel::Base.set_callback(:subscribe, :around) do |channel, block|
      BenchMetrics.instrument_action_cable_subscription(channel, &block)
    end

    @action_cable_hooks_installed = true
  end

  # Class names whose instance counts we sample each tick. Listed by
  # name so referencing the constant is deferred — autoloading is lazy
  # and some of these live in code paths that may not be loaded yet.
  UPKEEP_INSTANCE_CLASS_NAMES = [
    "Upkeep::DAG::Graph",
    "Upkeep::Delivery::Transport::Connection",
    "Upkeep::Replay::Recipe",
    "Upkeep::Runtime::ObservedHash",
    "Upkeep::Runtime::ObservedRequest",
    "Upkeep::Runtime::ObservedWarden",
    "Upkeep::Runtime::Recorder",
    "Upkeep::Subscriptions::ReverseIndex",
    "Upkeep::Subscriptions::Store"
  ].freeze

  ACTION_CABLE_INSTANCE_CLASS_NAMES = [
    "ActionCable::Connection::Base",
    "ActionCable::Channel::Base",
    "Turbo::StreamsChannel"
  ].freeze

  # Sample top types from ObjectSpace.count_objects each tick. Cap the
  # emitted subset so the JSONL stays compact — 20 types is plenty to
  # attribute 2M live slots.
  OBJECT_COUNT_TOP_N = 20

  def self.start_memory_sampler
    sample_rss! # seed immediately so /bench/metrics is never 0 on first poll
    Thread.new do
      loop do
        sleep 5
        rss_kb = sample_rss!
        emit(event: "memory_sample", extra: { memory_rss_mb: (rss_kb / 1024.0).round(1) })
        emit_memory_snapshot(rss_kb)
      rescue => e
        Rails.logger.warn("Benchmark memory sampler error: #{e.message}")
      end
    end
  end

  def self.emit_memory_snapshot(rss_kb = nil, phase: nil, force_gc: false)
    GC.start(full_mark: true, immediate_sweep: true) if force_gc
    rss_kb ||= sample_rss!
    Upkeep::Telemetry.memory_snapshot(**memory_snapshot_payload(rss_kb, phase: phase, deep_retention: force_gc, anchor_alloc_delta: force_gc))
  end

  def self.memory_snapshot_payload(rss_kb, phase: nil, store: current_subscription_store, deep_retention: false, anchor_alloc_delta: false)
    gc = GC.stat
    object_counts = ObjectSpace.count_objects
      .reject { |k, _| k == :TOTAL || k == :FREE }
      .sort_by { |_, v| -v }
      .first(OBJECT_COUNT_TOP_N)
      .to_h

    upkeep_counts = {}
    UPKEEP_INSTANCE_CLASS_NAMES.each do |name|
      klass = resolve_const(name)
      next unless klass
      upkeep_counts[name] = ObjectSpace.each_object(klass).count
    rescue StandardError
      # Some classes (e.g., Data.define subclasses) may not support each_object; skip silently.
      next
    end

    payload = {
      rss_mb: (rss_kb / 1024.0).round(1),
      heap_allocated_pages: gc[:heap_allocated_pages],
      heap_sorted_length: gc[:heap_sorted_length],
      heap_allocatable_pages: gc[:heap_allocatable_pages],
      heap_available_slots: gc[:heap_available_slots],
      heap_live_slots: gc[:heap_live_slots],
      heap_free_slots: gc[:heap_free_slots],
      total_allocated_objects: gc[:total_allocated_objects],
      total_freed_objects: gc[:total_freed_objects],
      gc_count: gc[:count],
      major_gc_count: gc[:major_gc_count],
      malloc_increase_bytes: gc[:malloc_increase_bytes],
      malloc_increase_bytes_limit: gc[:malloc_increase_bytes_limit],
      old_objects: gc[:old_objects],
      oldmalloc_increase_bytes: gc[:oldmalloc_increase_bytes],
      oldmalloc_increase_bytes_limit: gc[:oldmalloc_increase_bytes_limit],
      action_cable_counts: action_cable_counts,
      object_counts: object_counts,
      upkeep_instance_counts: upkeep_counts,
      retained_owner_counts: deep_retention_enabled?(anchor_alloc_delta) ? retained_owner_counts(store) : {}
    }
    payload[:objectspace_memsize_bytes] = ObjectSpace.memsize_of_all if ObjectSpace.respond_to?(:memsize_of_all)
    payload[:allocation_delta] = allocation_delta(gc, phase: phase, anchor: anchor_alloc_delta)
    if deep_retention_enabled?(deep_retention)
      payload[:class_retention_bytes] = class_retention_bytes
      payload[:allocation_sites] = allocation_sites
    end
    payload[:phase] = phase if phase
    payload
  end

  # Per-snapshot allocation / GC pressure delta (M1). Only phase-marker
  # emits (force_gc'd, with `anchor: true`) advance `@last_alloc_snapshot`.
  # Steady-state sampler emits compute deltas against the most recent
  # phase anchor without overwriting it, so the report's
  # phase-to-phase deltas describe phase boundaries even when the
  # untagged sampler thread runs between them.
  def self.allocation_delta(gc, phase: nil, anchor: false)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    gc_time_ms = GC::Profiler.enabled? ? (GC::Profiler.total_time * 1000.0) : nil

    snapshot = {
      ts: now,
      total_allocated_objects: gc[:total_allocated_objects].to_i,
      total_freed_objects: gc[:total_freed_objects].to_i,
      gc_count: gc[:count].to_i,
      major_gc_count: gc[:major_gc_count].to_i,
      minor_gc_count: gc[:minor_gc_count].to_i,
      oldmalloc_increase_bytes: gc[:oldmalloc_increase_bytes].to_i,
      gc_time_ms: gc_time_ms,
      phase: phase
    }

    prev = @last_alloc_snapshot
    @last_alloc_snapshot = snapshot if anchor

    return { ts: now, gc_time_ms_total: gc_time_ms&.round(1), seed: true } unless prev

    elapsed_s = [ now - prev[:ts], 0.0001 ].max
    allocated = snapshot[:total_allocated_objects] - prev[:total_allocated_objects]
    freed = snapshot[:total_freed_objects] - prev[:total_freed_objects]
    gc_runs = snapshot[:gc_count] - prev[:gc_count]
    major_runs = snapshot[:major_gc_count] - prev[:major_gc_count]
    minor_runs = snapshot[:minor_gc_count] - prev[:minor_gc_count]
    gc_time_delta_ms = gc_time_ms && prev[:gc_time_ms] ? (gc_time_ms - prev[:gc_time_ms]) : nil

    {
      since_phase: prev[:phase],
      elapsed_s: elapsed_s.round(3),
      allocated_objects: allocated,
      freed_objects: freed,
      retained_objects: allocated - freed,
      allocations_per_s: (allocated / elapsed_s).round(0),
      gc_runs: gc_runs,
      major_gc_runs: major_runs,
      minor_gc_runs: minor_runs,
      gc_time_delta_ms: gc_time_delta_ms&.round(1),
      gc_time_share: (gc_time_delta_ms && elapsed_s > 0) ? (gc_time_delta_ms / (elapsed_s * 1000.0)).round(4) : nil,
      gc_time_ms_total: gc_time_ms&.round(1)
    }
  end

  # Deep per-class retention attribution (M2). Walks every live object
  # once and groups retained bytes by class. Expensive — gated to
  # phase-boundary calls and opt-in via BENCH_CLASS_RETENTION=1, or
  # always on when running a force_gc'd peak phase.
  CLASS_RETENTION_TOP_N = 30

  # Deep retention attribution walks every live object. Restrict to
  # phase boundaries where GC was forced (caller's intent: "this is a
  # measurement phase") or to opt-in env. Steady-state samplers must
  # not trigger it.
  def self.deep_retention_enabled?(force_gc_phase)
    require "objspace" unless ObjectSpace.respond_to?(:memsize_of)
    return false unless ObjectSpace.respond_to?(:memsize_of)
    return true if ENV["BENCH_CLASS_RETENTION"] == "1"
    force_gc_phase
  end

  def self.class_retention_bytes
    counts = Hash.new(0)
    bytes = Hash.new(0)
    ObjectSpace.each_object do |obj|
      cls = obj.class.name || obj.class.to_s
      counts[cls] += 1
      bytes[cls] += ObjectSpace.memsize_of(obj)
    rescue StandardError
      next
    end
    bytes
      .sort_by { |_, v| -v }
      .first(CLASS_RETENTION_TOP_N)
      .each_with_object({}) { |(cls, b), out| out[cls] = { bytes: b, count: counts[cls] } }
  rescue StandardError
    {}
  end

  # Walks every per-subscriber field in the broker's subscriber map
  # under a single broker round-trip; the broker's worker thread
  # blocks on that walk for the duration. The walk's cost grows with
  # subscriber count (and is non-trivial: per-field
  # `accumulate_owner_counts` recursion + `ObjectSpace.memsize_of` on
  # every node). Steady-state samplers must NOT call it — under load
  # it stalls every other broker op behind it. Gate at the call site
  # via `deep_retention_enabled?` so the walk fires only at
  # force-GC'd phase boundaries (when memory-ceiling reports want a
  # snapshot) or under opt-in `BENCH_CLASS_RETENTION=1`.
  def self.retained_owner_counts(store = current_subscription_store)
    return {} unless store
    return store.benchmark_retained_owner_counts if store.respond_to?(:benchmark_retained_owner_counts)

    {}
  end

  def self.action_cable_counts
    counts = {}

    ACTION_CABLE_INSTANCE_CLASS_NAMES.each do |name|
      klass = resolve_const(name)
      next unless klass
      counts[name] = ObjectSpace.each_object(klass).count
    rescue StandardError
      next
    end

    stream_entries = action_cable_stream_entries
    counts["stream_registry.entries"] = stream_entries unless stream_entries.nil?
    counts
  end

  def self.action_cable_stream_entries
    channel_class = resolve_const("ActionCable::Channel::Base")
    return unless channel_class

    ObjectSpace.each_object(channel_class).sum do |channel|
      next 0 unless channel.instance_variable_defined?(:@streams)

      streams = channel.instance_variable_get(:@streams)
      streams.respond_to?(:size) ? streams.size : 0
    end
  rescue StandardError
    nil
  end

  def self.resolve_const(name)
    name.split("::").inject(Object) { |ns, part| ns.const_get(part) }
  rescue NameError
    nil
  end

  def self.subscription_count
    store = current_subscription_store
    return unless store

    if store.respond_to?(:summary)
      store.summary.fetch(:subscriptions, nil)
    elsif store.respond_to?(:size)
      store.size
    end
  end

  def self.current_subscription_store
    if defined?(Upkeep::Rails) && Upkeep::Rails.respond_to?(:subscriptions)
      return Upkeep::Rails.subscriptions
    end

    return unless defined?(Upkeep::Runtime) && Upkeep::Runtime.respond_to?(:subscription_store)

    Upkeep::Runtime.subscription_store
  rescue StandardError
    nil
  end

  def self.memory_phase_from_env(env)
    query = env["QUERY_STRING"].to_s
    query.split("&").each do |pair|
      key, value = pair.split("=", 2)
      next unless key == "memory_phase"
      phase = value.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
      return phase unless phase.empty?
    end
    nil
  end

  def self.install_endpoint
    # no-op — endpoint is mounted via routes
  end

  def self.emit_notification(notification:, event:, extra: {})
    emit(
      event: event,
      duration_ms: notification.duration,
      extra: extra.merge(
        started_wall_time_ms: (notification.time.to_f * 1000).round(3),
        finished_wall_time_ms: (notification.end.to_f * 1000).round(3)
      )
    )
  end

  def self.request_params_hash(params)
    case params
    when nil
      {}
    else
      params.respond_to?(:to_h) ? params.to_h : Hash(params)
    end
  rescue StandardError
    {}
  end

  def self.parse_json(value)
    return value unless value.is_a?(String)

    JSON.parse(value)
  rescue JSON::ParserError
    {}
  end

  def self.request_fullpath(request)
    return unless request

    request.respond_to?(:fullpath) ? request.fullpath : request.path
  rescue StandardError
    nil
  end

  def self.action_dispatch_request(env)
    return unless env

    environment = Rails.application.env_config.merge(env) if defined?(Rails.application) && Rails.application
    ActionDispatch::Request.new(environment || env)
  rescue StandardError
    nil
  end

  private_class_method :setup_log_file, :emit, :setup_counters, :subscribe_notifications,
                       :start_memory_sampler, :sample_rss!, :subscription_count, :install_endpoint,
                       :emit_notification, :request_params_hash, :parse_json, :request_fullpath,
                       :action_dispatch_request, :install_action_cable_hooks, :current_subscription_store,
                       :memory_phase_from_env, :upkeep_reactivity_snapshot,
                       :subscription_graphs_snapshot, :empty_subscription_graph_summary,
                       :accumulate_subscription_graph_summary, :finish_subscription_graph_summary,
                       :replay_recipe_bytes, :shared_stream_names_count,
                       :refused_boundaries_snapshot, :upkeep_delivery_snapshot,
                       :setup_reactivity_counters, :increment_reactivity_tally,
                       :reactivity_tally_snapshot, :sorted_hash,
                       :action_cable_counts, :action_cable_stream_entries,
                       :allocation_delta, :class_retention_bytes, :deep_retention_enabled?,
                       :start_allocation_trace!, :allocation_sites, :shorten_path
end
