module RefreshSync
  # Controller integration: capture successful HTML GETs, register a cohort,
  # observe surface promotion evidence, and expose the cohort stream.
  module Capture
    extend ActiveSupport::Concern

    singleton_class.attr_accessor :enabled
    self.enabled = true

    class_methods do
      def refresh_sync(**options)
        around_action :_refresh_sync_capture, **options
        helper SurfaceHelper if respond_to?(:helper)
      end
    end

    private

    def _refresh_sync_capture
      return yield unless Capture.enabled && request.get?

      recording = Recording.start(
        request_id: request.headers["X-Turbo-Request-Id"] || request.request_id
      )
      begin
        yield
      ensure
        Recording.finish
      end

      return unless response.successful? && response.media_type == "text/html"

      cohort = RefreshSync.store.register(
        read_set: recording.read_set,
        surfaces: recording.surfaces.map { |o| o.descriptor.name }
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
    end
  end

  # View-side declaration of a shareable region. Explicit by design in this
  # prototype (the real gem could hook partial rendering instead): it renders
  # the partial normally for this viewer and records the surface evidence.
  module SurfaceHelper
    def shared_surface(name, partial:, **locals)
      html = render(partial: partial, locals: locals)
      Recording.current&.record_surface(name: name, partial: partial, locals: locals, html: html)
      html
    end
  end
end
