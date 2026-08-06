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

      cohort = RefreshSync.store.register(
        read_set: recording.read_set,
        surfaces: recording.surfaces.map { |o| o.descriptor.name },
        # Region-digest baseline from THIS capture's render: the digests are
        # already computed for surface evidence, and they describe exactly
        # the page state this viewer holds — so the first region broadcast
        # can diff instead of sending every region.
        baselines: recording.surfaces.to_h { |o| [o.descriptor.name, o.node_digests || {}] }
      )
      viewer = Ambient.unobserved { RefreshSync.viewer_resolver&.call(request) }
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
      generations = recording.surfaces.filter_map do |o|
        s = RefreshSync.registry.lookup(o.descriptor.name)
        "#{o.descriptor.name}=#{s.generation}" if s
      end
      response.set_header("X-RefreshSync-Generation", generations.join(",")) if generations.any?
    end
  end

  # View-side declaration of a shareable region. Explicit by design in this
  # prototype (the real gem could hook partial rendering instead): it renders
  # the partial normally for this viewer and records the surface evidence.
  module SurfaceHelper
    def shared_surface(name, partial:, **locals)
      recording = Recording.current
      marker = recording&.prov&.segment_marker
      html = render(partial: partial, locals: locals)
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
