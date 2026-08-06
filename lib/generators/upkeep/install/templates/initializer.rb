# Upkeep configuration. Every knob that exists is listed; commented
# lines show the default.
Rails.application.config.to_prepare do
  # Durable store + cross-process debounce (production defaults). The test
  # environment can keep the in-memory store per test-suite setup instead.
  Upkeep.store = Upkeep::ActiveRecordStore.new
  Upkeep.registry = Upkeep::ActiveRecordSurfaceRegistry.new
  Upkeep.debouncer = Upkeep::Debouncer.new(
    window: 0.3,                        # debounce window (seconds)
    refresh_budget: 8,                  # max refreshes per tick; rest drain across jittered windows
    claimer: Upkeep::DbClaimer.new # cross-process dedupe
  )

  # Identity seam: resolve the authenticated viewer for a captured request.
  # Return nil for anonymous. Identity fails closed: unauthenticated viewers
  # never count as surface promotion evidence.
  # Upkeep.viewer_resolver = ->(request) do
  #   user = request.env["warden"]&.user(:user)
  #   user && Upkeep::Viewer.new(id: user.id, role: user.role)
  # end

  # Scrubbed Tier S renderer: bare controller, app view paths, NO app helpers.
  # Upkeep.renderer_class = Upkeep::ScrubRenderer

  # Columns whose presence in a read-set predicate marks a page as
  # identity-bound (permanently Tier P for the deploy).
  # Upkeep.identity_columns = %w[user_id]

  # Cache-bust promotion evidence per deploy.
  # Upkeep.deploy_key = ENV.fetch("HEROKU_RELEASE_VERSION", "deploy-1")

  # Tier S payload cap in bytes (nil = unlimited); oversized deliveries
  # degrade to a refresh, loudly.
  # Upkeep.payload_limit = 64_000

  # Additional infrastructure tables to ignore (writes to them never trigger
  # matching; a loud warning fires if an active cohort depends on one).
  # Upkeep.ignored_tables += %w[ahoy_events]

  # Registration is opt-in per controller:
  #   include Upkeep::Capture
  #   upkeep only: [:index, :show]
  # Global kill switch:
  # Upkeep::Capture.enabled = true

  # Response-body injection of the stock <turbo-cable-stream-source>
  # subscription elements (the zero-JS client). Disable to place them
  # yourself.
  # Upkeep::Streams.auto_subscribe = true

  # Provenance: which view roots compile through Herb (byte-identical,
  # instrumented) and which additionally get data-upkeep-node stamps for region
  # broadcast targeting.
  Upkeep::Provenance.instrument_paths = [Rails.root.join("app/views").to_s]
  Upkeep::Provenance.stamp_paths = [Rails.root.join("app/views").to_s]
  Upkeep::Provenance.install!
end
