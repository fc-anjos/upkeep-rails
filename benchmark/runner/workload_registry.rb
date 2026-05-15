# frozen_string_literal: true

require_relative "types"

module Upkeep
  module Benchmark
    module Runner
      class WorkloadRegistry
        attr_reader :config

        def initialize(config)
          @config = config
        end

        def resolve
          key = "#{config.family}/#{config.workload_name}"
          workload = case key
          # ── Matrix ──────────────────────────────────────────────
          when "matrix/compare", "matrix/warm_steady_state_chat"
            require_tier!(key, "gate", "report")
            build(key, needs_turbo: true, vus: tier_vus(report: 200, gate: 50))
          when "matrix/cold_connect_churn_chat"
            require_tier!(key, "gate", "report")
            build(key, needs_turbo: true, vus: tier_vus(report: 200, gate: 50), capacity_gate: true)
          when "matrix/pipeline_smoke"
            require_tier!(key, "smoke")
            build(key, needs_turbo: false)
          # ── Render dedup ────────────────────────────────────────
          when "render_dedup/shared_identity_free"
            require_tier!(key, "gate", "report")
            build(key,
              route_script: route_script_for("render_dedup/shared_identity_free"),
              post_label: "after-render-dedup-shared-identity-free",
              vus: tier_vus(report: 200, gate: 50))
          when "render_dedup/isolated"
            require_tier!(key, "gate", "report")
            build(key,
              route_script: route_script_for("render_dedup/isolated"),
              post_label: "after-render-dedup-isolated",
              vus: tier_vus(report: 200, gate: 50))
          when "render_dedup/mixed_region_feed"
            require_tier!(key, "gate", "report")
            build(key,
              route_script: route_script_for("render_dedup/mixed_region_feed"),
              post_label: "after-render-dedup-mixed-region-feed",
              vus: tier_vus(report: 200, gate: 50))
          when "render_dedup/featured_item_compare"
            require_tier!(key, "gate", "report")
            build(key, needs_turbo: true, vus: tier_vus(report: 200, gate: 50))
          when "render_dedup/identity_free_feed_compare"
            require_tier!(key, "gate", "report")
            build(key, needs_turbo: true, vus: tier_vus(report: 200, gate: 50))
          when "render_dedup/mixed_region_feed_ivar"
            require_tier!(key, "ci", "gate", "report")
            apply_ivar_steady_seconds!
            build(key,
              route_script: route_script_for("render_dedup/mixed_region_feed_ivar"),
              post_label: "after-render-dedup-mixed-region-feed-ivar",
              vus: tier_vus(report: 200, gate: 50, smoke: 5, ci: 5))
          # ── Classifier ──────────────────────────────────────────
          when "classifier/identity_free_feed"
            require_tier!(key, "gate", "report")
            build(key,
              route_script: route_script_for("classifier/identity_free_feed"),
              post_label: "after-classifier-identity-free-feed",
              vus: tier_vus(report: 200, gate: 50))
          # ── Render parallelism ──────────────────────────────────
          when "render_parallelism/fallback_contradiction"
            require_tier!(key, "gate", "report")
            build(key,
              route_script: route_script_for("render_parallelism/fallback_contradiction"),
              post_label: "after-render-parallelism-fallback-contradiction",
              vus: tier_vus(report: 200, gate: 50))
          when "render_parallelism/sweep"
            require_tier!(key, "gate", "report")
            build(key, top_level: "render_parallelism_sweep", vus: tier_vus(report: 200, gate: 50))
          # ── Memory ceiling ──────────────────────────────────────
          when "memory_ceiling/topology_sweep"
            require_tier!(key, "smoke", "report")
            build(key, top_level: "memory_ceiling_topology_sweep", vus: tier_vus(report: 200, smoke: 5))
          when "memory_ceiling/shared_feed_churn"
            require_tier!(key, "smoke", "report")
            build(key, needs_turbo: true, vus: tier_vus(report: 500, smoke: 50))
          else
            raise WorkloadError, "unknown benchmark workload: #{key}"
          end

          config.upkeep_only? ? workload.with(needs_turbo: false) : workload
        end

        private
          def tier_vus(report:, gate: nil, smoke: nil, ci: nil)
            return config.integer_env("BENCH_VUS", report) if config.tier == "report"
            return config.integer_env("BENCH_VUS", smoke) if config.tier == "smoke" && smoke
            return config.integer_env("BENCH_VUS", ci) if config.tier == "ci" && ci

            config.integer_env("BENCH_VUS", gate || report)
          end

          def route_script_for(relative)
            File.join(config.bench_dir, "routes/#{relative}.rb")
          end

          # render_dedup/mixed_region_feed_ivar uses tier-specific
          # steady-state durations (matches the shell runner's per-tier
          # IVAR_FEED_STEADY_S knob). Set the env var so the route
          # script picks it up; an explicit caller override stays in
          # control.
          IVAR_STEADY_BY_TIER = {
            "ci" => 5,
            "gate" => 50,
            "report" => 200
          }.freeze

          def apply_ivar_steady_seconds!
            return if config.env.key?("IVAR_FEED_STEADY_S")

            steady = IVAR_STEADY_BY_TIER[config.tier]
            config.env["IVAR_FEED_STEADY_S"] = steady.to_s if steady
          end

          def require_tier!(name, *allowed)
            return if allowed.include?(config.tier)

            raise WorkloadError, "#{name} supports tiers #{allowed.join(", ")}"
          end

          def build(key, needs_turbo: false, route_script: nil, post_label: nil, top_level: nil, vus: nil, capacity_gate: false)
            Workload.new(
              key: key,
              needs_turbo: needs_turbo,
              route_script: route_script,
              post_label: post_label,
              top_level: top_level,
              vus: vus,
              capacity_gate: capacity_gate
            )
          end
      end
    end
  end
end
