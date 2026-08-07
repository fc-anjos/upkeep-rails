module Upkeep
  # A page (or a query) fell out of liveness entirely. Raised in development
  # and test so the loss is impossible to miss where developers look;
  # production keeps the unchanged warn-and-degrade behavior.
  class LivenessLost < StandardError; end

  # An *.upkeep event was emitted that Legibility::TIERS does not classify.
  # Raised unconditionally in development/test: adding an event without
  # deciding its stakes is not allowed, and this raise is the enforcement.
  class UnclassifiedEvent < StandardError; end

  # Liveness legibility. The gem already warns about every degradation via
  # *.upkeep notifications — but a notification nobody subscribes to is
  # silence. This module is the single place every event is classified by
  # stakes, and the dev/test teeth behind the LIVENESS LOST class:
  #
  #   :lost       the page or a query is out of liveness entirely
  #               (no cohort, unattributable write, activation impossible,
  #               undeliverable cable topology). Dev/test: raise, naming the
  #               construct, its app-code location, and the fix. Production:
  #               unchanged (the event is the warning; delivery degrades).
  #   :coarsened  still live, just less precise (table-level fallback,
  #               Tier S stepping aside, payload degrade). Never raises;
  #               surfaced by the dev request summary and upkeep:report.
  #   :info       normal operation signals.
  #
  # UPKEEP_NO_RAISE=1 downgrades :lost to the production warn-and-degrade
  # path for teams mid-migration. It never silences UnclassifiedEvent.
  module Legibility
    # Exhaustive: every event the gem emits. Callables resolve tiers that
    # depend on the payload.
    TIERS = {
      "capture_refused" => :lost,
      "capture_incomplete" => ->(p) { p[:mode] == :unattributable ? :lost : :coarsened },
      "unattributed_write" => :lost,
      "ignored_table_write_skipped" => :lost,
      "subscribe_injection_skipped" => :lost,
      "cable_topology" => ->(p) { p[:verdict] == :broken ? :lost : :info },
      "row_identity_unavailable" => :coarsened,
      "payload_limit_degrade" => :coarsened,
      "region_unrenderable_degrade" => :coarsened,
      "region_unbroadcastable" => :coarsened,
      "provenance_compile_failed" => :coarsened,
      "scrubbed_render_failed" => :coarsened,
      "surface_pinned" => :coarsened,
      "surface_demoted" => :coarsened,
      "register" => :info,
      "refresh_netted" => :info,
      "reconnect_refresh" => :info,
      "member_diverged" => :info,
      "member_readmitted" => :info,
      "surface_observed" => :info,
      "surface_promoted" => :info,
      "surface_broadcast_sent" => :info,
      "surface_region_broadcast_sent" => :info,
      "surface_broadcast_dropped" => :info
    }.freeze

    GEM_LIB = File.expand_path("..", __dir__)
    RUBY_PREFIX = RbConfig::CONFIG["prefix"]

    class << self
      # Test seam (like Upkeep.clock): pin the environment instead of
      # rebooting Rails. nil falls back to Rails.env.
      attr_writer :env

      def env
        @env || (defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env.to_s : "production")
      end

      def enforcing? = %w[development test].include?(env.to_s)
      def raise_lost? = enforcing? && ENV["UPKEEP_NO_RAISE"] != "1"

      def tier_for(event, payload = {})
        tier = TIERS[event]
        return tier.respond_to?(:call) ? tier.call(payload) : tier if tier
        return :info unless enforcing?
        raise UnclassifiedEvent,
              "[upkeep] the event \"#{event}.upkeep\" is not classified in " \
              "Upkeep::Legibility::TIERS. Every event must declare its stakes " \
              "(:lost, :coarsened or :info) — add it to the map."
      end

      # Subscribed only in development/test: production pays nothing and
      # keeps its behavior byte-for-byte.
      def install!
        return if @installed || !enforcing?
        @installed = true
        ActiveSupport::Notifications.subscribe(/\.upkeep\z/) do |name, *_args, payload|
          observe(name.delete_suffix(".upkeep"), payload || {})
        end
      end

      def observe(event, payload)
        tier = tier_for(event, payload)
        raise LivenessLost, lost_message(event, payload) if tier == :lost && raise_lost?
      end

      # First stack frame in application code — past the gem, past Rails,
      # past the stdlib — so the raise points where the fix goes.
      def app_frame
        location = caller_locations(1, 80)&.find { |l| app_path?(l.path.to_s) }
        location && "#{location.path.delete_prefix("#{root}/")}:#{location.lineno}"
      end

      private

      def root
        defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : Dir.pwd
      end

      def app_path?(path)
        !path.start_with?(GEM_LIB, RUBY_PREFIX, "<internal") && !path.include?("/gems/")
      end

      def lost_message(event, payload)
        what, fix = explanation(event, payload)
        lines = ["[upkeep] liveness lost: #{what}"]
        frame = app_frame
        lines << "  at: #{frame}" if frame
        lines << "  fix: #{fix}"
        lines << "  (production behavior is unchanged: warn and degrade. " \
                 "Set UPKEEP_NO_RAISE=1 to opt out while migrating.)"
        lines.join("\n")
      end

      def explanation(event, payload)
        case event
        when "capture_refused" then refused(payload)
        when "capture_incomplete" then incomplete(payload)
        when "unattributed_write" then unattributed(payload)
        when "ignored_table_write_skipped" then ignored_write(payload)
        when "subscribe_injection_skipped" then injection_skipped
        when "cable_topology" then topology(payload)
        end
      end

      def refused(payload)
        ["an unattributable query (#{payload[:detail].inspect}) ran while " \
         "capturing #{payload[:path]} — the read set cannot vouch for the " \
         "page, so no cohort was registered and the page is NOT live.",
         QUERY_FIX]
      end

      def incomplete(payload)
        ["the query #{(payload[:query_name] || "unnamed").inspect} is " \
         "unattributable: no read door accounts for it and no model name " \
         "identifies its table. The capture will refuse precision — no " \
         "cohort, page NOT live.",
         QUERY_FIX]
      end

      QUERY_FIX = "run the read through Active Record, name it with the " \
                  "\"Model Action\" convention (select_all(sql, \"Card Load\")), " \
                  "or opt the request out of capture.".freeze

      def unattributed(payload)
        ["a write (#{payload[:sql_head].inspect}...) could not be attributed " \
         "to any table — pages depending on the written rows will NOT update.",
         "issue the write through a model or relation, or — if the table is " \
         "infrastructure — add it to Upkeep.ignored_tables."]
      end

      def ignored_write(payload)
        ["a write to the ignored table \"#{payload[:table]}\" was skipped, " \
         "but an active page depends on that table — the page is now stale " \
         "and will NOT update.",
         "remove \"#{payload[:table]}\" from Upkeep.ignored_tables, or stop " \
         "rendering live pages from it."]
      end

      def injection_skipped
        ["the captured response has no </body>, so the subscription tags " \
         "could not be injected — the browser will never subscribe and the " \
         "page is NOT live.",
         "render a full HTML layout with a <body>, or set " \
         "Upkeep::Streams.auto_subscribe = false and place the stream tags " \
         "yourself."]
      end

      def topology(payload)
        ["the async Action Cable adapter cannot deliver across processes, " \
         "and WEB_CONCURRENCY=#{payload[:web_concurrency]} runs a " \
         "multi-process server — updates WILL be silently lost between workers.",
         "use a cross-process cable adapter (solid_cable, redis, postgresql) " \
         "in config/cable.yml."]
      end
    end
  end
end
