module RefreshSync
  # Controller integration: capture successful HTML GETs, register a cohort,
  # observe surface promotion evidence, and expose the cohort stream.
  module Capture
    extend ActiveSupport::Concern

    singleton_class.attr_accessor :enabled
    singleton_class.attr_accessor :last_recording # test/introspection hook
    self.enabled = true

    class_methods do
      def refresh_sync(**options)
        around_action :_refresh_sync_capture, **options
        helper SurfaceHelper if respond_to?(:helper)
      end
    end

    # Cohorts register only for genuine browser HTML requests: HTML format
    # (Pulse's chatbot speaks application/x-llm), not XHR/fetch, and not in
    # a suppressed context (job-driven in-process integration sessions).
    def self.registrable?(request)
      return false if RefreshSync.registration_suppressed?
      return false if request.xhr?
      format = request.format
      format.nil? || format.html?
    end

    private

    def _refresh_sync_capture
      return yield unless Capture.enabled && request.get? && Capture.registrable?(request)

      recording = Recording.start(
        request_id: request.headers["X-Turbo-Request-Id"] || request.request_id
      )
      begin
        yield
      ensure
        Recording.finish
        Capture.last_recording = recording
      end

      return unless response.successful? && response.media_type == "text/html"

      # Completeness audit verdict: an unattributable unhooked read ran
      # during this capture, so the read set cannot vouch for the page.
      # Refuse precision — no cohort, no liveness — LOUDLY, rather than
      # registering a read set with a silent hole in it.
      if recording.incomplete?
        RefreshSync.stats[:captures_refused] += 1
        ActiveSupport::Notifications.instrument(
          "capture_refused.refresh_sync",
          reason: :unattributable_read, detail: recording.incomplete_detail,
          path: request.path
        )
        return
      end

      register_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      viewer = Ambient.unobserved { RefreshSync.viewer_resolver&.call(request) }
      cohort = RefreshSync.store.register(
        read_set: recording.read_set,
        surfaces: recording.surfaces.map { |o| o.descriptor.name },
        # Viewer identity rides on the cohort so a write to the member's own
        # delta rows can eject exactly this member from shared delivery.
        identity: viewer&.id&.to_s,
        # Region-digest baseline from THIS capture's render: the digests are
        # already computed for surface evidence, and they describe exactly
        # the page state this viewer holds — so the first region broadcast
        # can diff instead of sending every region.
        baselines: recording.surfaces.to_h { |o| [o.descriptor.name, o.node_digests || {}] }
      )
      recording.surfaces.each do |observation|
        surface = RefreshSync.registry.upsert(observation.descriptor.name)
        surface.observe(
          observation,
          viewer: viewer,
          cohort_stream: cohort.stream,
          ambient: recording.ambient,
          identity_bound: recording.identity_bound?
        )
      end
      response.set_header("X-RefreshSync-Stream", cohort.stream)
      # Delivery-ordering stamp: the write generation of every surface on
      # this page, at render time. The client compares it against the
      # data-rs-gen carried by region updates: a full-page morph whose
      # generation is OLDER than an already-applied region update must not
      # be applied (it would silently roll the region back) — the client
      # discards it and re-fetches. See README "Delivery-ordering
      # invariant".
      generations = []
      surface_streams = []
      recording.surfaces.each do |o|
        s = RefreshSync.registry.lookup(o.descriptor.name)
        next unless s
        generations << "#{o.descriptor.name}=#{s.generation}"
        # An ejected member's page must not subscribe to the shared surface
        # stream at all — their delivery is personal Tier P (cohort stream)
        # until their render matches the shared baseline again.
        surface_streams << s.stream unless s.member_diverged?(viewer&.id)
      end
      response.set_header("X-RefreshSync-Generation", generations.join(",")) if generations.any?

      # Zero-JS client: stock <turbo-cable-stream-source> elements, signed
      # with Turbo's own verifier (the signed name doubles as the activation
      # token — it exists only in this authenticated response).
      if Streams.auto_subscribe
        Streams.inject_sources(response, [cohort.stream] + surface_streams)
      end

      # Benchmark/ops instrumentation: what registration cost this request.
      ActiveSupport::Notifications.instrument(
        "register.refresh_sync",
        path: request.path,
        register_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - register_started) * 1000.0).round(3),
        tables: recording.read_set.tables.keys.size,
        surfaces: recording.surfaces.size
      )
    end
  end

  # View-side declaration of a shareable region. Explicit by design in this
  # prototype (the real gem could hook partial rendering instead): it renders
  # the partial normally for this viewer and records the surface evidence.
  module SurfaceHelper
    def shared_surface(name, partial:, **locals)
      recording = Recording.current
      marker = recording&.prov&.segment_marker
      html = AutoSurfaces.suppress { render(partial: partial, locals: locals) }
      if recording
        node_digests = recording.prov.node_digests_since(marker || {})
        node_texts = node_digests.keys.to_h { |a| [a, recording.prov.text_for(a)] }
        recording.record_surface(
          name: name, partial: partial, locals: locals, html: html,
          node_digests: node_digests, node_texts: node_texts
        )
      end
      html
    end
  end
end
