# RefreshSync configuration. Every knob that exists is listed; commented
# lines show the default.
Rails.application.config.to_prepare do
  # Durable store + cross-process debounce (production defaults). The test
  # environment can keep the in-memory store per test-suite setup instead.
  RefreshSync.store = RefreshSync::ActiveRecordStore.new
  RefreshSync.registry = RefreshSync::ActiveRecordSurfaceRegistry.new
  RefreshSync.debouncer = RefreshSync::Debouncer.new(
    window: 0.3,                        # debounce window (seconds)
    refresh_budget: 8,                  # max refreshes per tick; rest drain across jittered windows
    claimer: RefreshSync::DbClaimer.new # cross-process dedupe
  )

  # Identity seam: resolve the authenticated viewer for a captured request.
  # Return nil for anonymous. Identity fails closed: unauthenticated viewers
  # never count as surface promotion evidence.
  # RefreshSync.viewer_resolver = ->(request) do
  #   user = request.env["warden"]&.user(:user)
  #   user && RefreshSync::Viewer.new(id: user.id, role: user.role)
  # end

  # Scrubbed Tier S renderer: bare controller, app view paths, NO app helpers.
  # RefreshSync.renderer_class = RefreshSync::ScrubRenderer

  # Columns whose presence in a read-set predicate marks a page as
  # identity-bound (permanently Tier P for the deploy).
  # RefreshSync.identity_columns = %w[user_id]

  # Cache-bust promotion evidence per deploy.
  # RefreshSync.deploy_key = ENV.fetch("HEROKU_RELEASE_VERSION", "deploy-1")

  # Tier S payload cap in bytes (nil = unlimited); oversized deliveries
  # degrade to a refresh, loudly.
  # RefreshSync.payload_limit = 64_000

  # Additional infrastructure tables to ignore (writes to them never trigger
  # matching; a loud warning fires if an active cohort depends on one).
  # RefreshSync.ignored_tables += %w[ahoy_events]

  # Registration is opt-in per controller:
  #   include RefreshSync::Capture
  #   refresh_sync only: [:index, :show]
  # Global kill switch:
  # RefreshSync::Capture.enabled = true

  # Response-body injection of the stock <turbo-cable-stream-source>
  # subscription elements (the zero-JS client). Disable to place them
  # yourself.
  # RefreshSync::Streams.auto_subscribe = true

  # Provenance: which view roots compile through Herb (byte-identical,
  # instrumented) and which additionally get data-rs-node stamps for region
  # broadcast targeting.
  RefreshSync::Provenance.instrument_paths = [Rails.root.join("app/views").to_s]
  RefreshSync::Provenance.stamp_paths = [Rails.root.join("app/views").to_s]
  RefreshSync::Provenance.install!
end
