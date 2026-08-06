module Upkeep
  # Routes one committed fact. Per matching cohort: per-member divergence
  # ejection, Tier S coverage, and (when not covered) a scheduled Tier P
  # refresh carrying the cohort's own verdict of the fact. Touched surfaces
  # get their evidence-generation bump and, when promoted, a scheduled
  # shared broadcast.
  class Dispatch
    def initialize(fact)
      @fact = fact
      # A write committed during a captured GET carries that GET's request
      # id; the refresh tag is stamped with it so Turbo's native
      # client-side guard breaks the GET -> write -> refresh -> GET loop on
      # the origin tab. Writes from POST boundaries carry nil: the origin
      # tab is just another subscriber.
      @origin_request_id = Recording.current&.request_id
      # One hydrated surface object per name for this whole fact, so a
      # member ejection and the generation bump land on the same state (two
      # hydrations of the same row would overwrite each other on persist).
      @hydrated = Hash.new { |h, name| h[name] = Upkeep.registry.lookup(name) }
      @refreshes = {} # stream => verdict
      @touched = Set.new
    end

    def call
      Upkeep.store.matching_cohorts(@fact).each { |cohort| route(cohort) }
      @touched.each { |surface| advance(surface) }
      @refreshes.each do |stream, verdict|
        Upkeep.debouncer.schedule(
          stream, request_id: @origin_request_id, fact: @fact, verdict: verdict
        )
      end
    end

    private

    def route(cohort)
      surfaces = cohort.surfaces.filter_map { |name| @hydrated[name] }
      covering = surfaces.select { |s| s.tables.include?(@fact.table) }
      covering.each { |s| @touched << s }
      ejected = eject_diverged_member(cohort, surfaces)
      return if tier_s_covers?(cohort, covering, ejected)
      @refreshes[cohort.stream] = cohort.read_set ? cohort.read_set.verdict(@fact) : :maybe
    end

    # Per-member divergence (the flag-flip fix): this fact matches the
    # member's read set, but a promoted surface's scrub render never read
    # anything it touches — it changed something only this member depends
    # on (their user row, a role row). Shared delivery is now wrong for
    # THEM specifically: eject them to personal refresh, leave the surface
    # (and everyone else) shared.
    def eject_diverged_member(cohort, surfaces)
      return false unless cohort.identity
      ejected = false
      surfaces.each do |s|
        next unless s.personal_change?(@fact)
        s.eject_member!(cohort.identity, reason: :delta_row_write)
        ejected = true
      end
      ejected
    end

    # Tier S only when a promoted surface covers the fact FOR THIS MEMBER.
    # A fully :shared surface covers any change to its tables. A
    # :region_shared surface covers it only when every matched node
    # dependency of this cohort falls inside its broadcastable regions —
    # otherwise the cohort still needs a refresh (personal islands and
    # controller reads converge via Tier P; region updates never substitute
    # for changes they don't carry). An ejected member is never covered:
    # their delivery is personal until re-admission.
    def tier_s_covers?(cohort, covering, ejected)
      return false if ejected || Upkeep.region_broadcast_disabled?
      covering.any? do |s|
        next false if s.member_diverged?(cohort.identity)
        s.shared? ||
          (s.region_shared? && cohort.read_set &&
            cohort.read_set.change_covered_by?(@fact, Upkeep.region_span(s)))
      end
    end

    # Every covering write advances the surface's evidence generation —
    # even while :observing — so digests from before and after a data
    # change are never compared against each other (that would produce
    # false identity pins whenever a write lands between two viewers).
    def advance(surface)
      surface.bump_generation
      return unless surface.tier_s? && !Upkeep.region_broadcast_disabled?
      # Schedule by KEY, not by hydrated object: the closure rehydrates
      # through this process's registry at dispatch time, so a demotion
      # persisted by any process between schedule and fire is seen. (A
      # closure-captured surface holds a stale :shared status — the
      # cross-process demotion race.)
      registry = Upkeep.registry
      name = surface.name
      deploy_key = surface.deploy_key
      Upkeep.debouncer.schedule("surface:#{surface.key}", kind: :broadcast) do
        registry.lookup(name, deploy_key: deploy_key)&.broadcast!
      end
    end
  end
end
