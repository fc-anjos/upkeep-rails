require "digest"
require "set"

module Upkeep
  # A "surface" is a named shareable region: a partial + captured locals.
  # Promotion state machine, per (surface name, deploy key):
  #
  #   :observing      Tier P. Accumulating evidence. Transitions:
  #                     -> :personal       ambient read / identity predicate /
  #                                        unrefreshable locals / whole-surface
  #                                        digest divergence with no localizable
  #                                        stamped remainder / scrubbed-render
  #                                        divergence or error
  #                     -> :shared         >=2 authenticated identities (and >=2
  #                                        roles when required) with
  #                                        byte-identical digests in the same
  #                                        write generation, AND a scrubbed
  #                                        render whose digest matches theirs
  #                     -> :region_shared  same evidence bar, but divergence
  #                                        localized to personal-node islands
  #                                        (a proper subset of traced nodes)
  #                                        with a byte-shared stamped remainder
  #                                        the scrubbed render reproduces
  #   :shared         Tier S. One scrubbed render broadcast per write window.
  #   :region_shared  Tier S for the shared regions only: one scrubbed render,
  #                   broadcast as targeted replaces of stamped remainder
  #                   nodes; island content is NEVER broadcast (it exists only
  #                   in per-viewer renders, converged by Tier P refresh).
  #                     -> :personal       scrubbed render raises, or a later
  #                                        observation diverges on the shared
  #                                        remainder. Island divergence is
  #                                        expected and ignored.
  #   :personal       Terminal for this deploy key.
  #
  # Evidence digests are kept for the CURRENT write generation only; every
  # covering write clears them (digests across a data change are
  # incomparable). Personal-node islands are STRUCTURAL knowledge and survive
  # generation bumps. Identity fails closed; freshness fails open.
  Descriptor = Struct.new(:name, :partial, :locals, keyword_init: true) do
    def tables
      locals.values.filter_map do |v|
        if v.is_a?(ActiveRecord::Relation)
          v.klass.table_name
        elsif record_array?(v)
          v.first.class.table_name
        elsif v.is_a?(ActiveRecord::Base)
          v.class.table_name
        end
      end
    end

    def refreshable?
      locals.values.all? { |v| rebuildable_local?(v) }
    end

    def rebuildable_local?(v)
      case v
      when ActiveRecord::Relation
        # Persistable+re-runnable only when the where clause is a faithful
        # simple hash (rebuildable as klass.where(hash) in any process).
        v.where_clause.ast.nil? || simple_relation?(v)
      when Array
        # A homogeneous array of persisted records (pagy hands templates
        # plain Arrays) is rebuildable as an ordered id fetch. The page
        # COMPOSITION is frozen at capture — a row entering the page shows
        # up as scrub-render divergence and converges via refresh, so
        # freshness still fails open.
        record_array?(v)
      when ActiveRecord::Base
        v.persisted? # rebuildable as a pk fetch
      else
        scalar_local?(v)
      end
    end

    def scalar_local?(v)
      v.is_a?(Numeric) || v.is_a?(String) || v.is_a?(Symbol) ||
        v == true || v == false || v.nil?
    end

    def record_array?(v)
      v.is_a?(Array) && v.any? &&
        v.all? { |r| r.is_a?(ActiveRecord::Base) && r.class == v.first.class && r.persisted? }
    end

    def simple_relation?(rel)
      flat = rel.where_clause.ast.is_a?(Arel::Nodes::And) ? rel.where_clause.ast.children : [rel.where_clause.ast].compact
      rel.where_values_hash.size == flat.size
    end

    def to_h
      serialized = locals.transform_values do |v|
        if v.is_a?(ActiveRecord::Relation)
          { "__relation__" => v.klass.name, "where" => v.where_values_hash }
        elsif record_array?(v)
          { "__records__" => v.first.class.name, "ids" => v.map(&:id) }
        elsif v.is_a?(ActiveRecord::Base) && v.persisted?
          { "__record__" => v.class.name, "id" => v.id }
        else
          v
        end
      end
      { "name" => name, "partial" => partial, "locals" => serialized }
    end

    def self.from_h(h)
      locals = h.fetch("locals", {}).to_h do |k, v|
        value =
          if v.is_a?(Hash) && v["__relation__"]
            v["__relation__"].constantize.where(v.fetch("where", {}))
          elsif v.is_a?(Hash) && v["__records__"]
            klass = v["__records__"].constantize
            ids = v.fetch("ids", [])
            klass.where(id: ids).in_order_of(:id, ids).to_a
          elsif v.is_a?(Hash) && v["__record__"]
            v["__record__"].constantize.find(v["id"])
          else
            v
          end
        [k.to_sym, value]
      end
      new(name: h["name"], partial: h["partial"], locals: locals)
    end
  end

  SurfaceObservation = Struct.new(:descriptor, :digest, :node_digests, :node_texts, keyword_init: true)
  Viewer = Struct.new(:id, :role, keyword_init: true)

  class Surface
    attr_reader :name, :deploy_key, :status, :pin_reason, :descriptor,
                :cohort_streams, :generation, :last_broadcast,
                :personal_nodes, :region_addresses, :diverged_viewers,
                :shared_read_set

    def initialize(name:, deploy_key:)
      @name = name
      @deploy_key = deploy_key
      @status = :observing
      @pin_reason = nil
      @generation = 0
      @evidence = {} # current generation only: viewer_id(String) => {digest:, role:, nodes:}
      @cohort_streams = Set.new
      @last_broadcast = nil # {digest:, generation:, nodes:}
      @personal_nodes = Set.new  # all node addresses known to diverge per-viewer
      @region_addresses = []     # top-level stamped broadcastable remainder nodes
      @shared_read_set = nil     # what the promoted scrub render itself read
      @diverged_viewers = Set.new # viewer ids ejected to personal delivery
      @generation_mismatches = Set.new # viewers that mismatched THIS generation's broadcast
    end

    def key = "#{@deploy_key}/#{@name}"
    def stream = "upkeep:surface:#{key}"
    def shared? = @status == :shared
    def region_shared? = @status == :region_shared
    def tier_s? = shared? || region_shared?
    def tables = @descriptor ? @descriptor.tables : []

    # Innermost personal nodes — the islands, for reporting and assertions.
    def islands
      @personal_nodes.reject do |address|
        @personal_nodes.any? { |other| other != address && other.start_with?("#{address}.") }
      end.sort
    end

    # --- per-member divergence -----------------------------------------------
    # The flag-flip fix. A write that matches a MEMBER's read set but not the
    # scrub render's read set changed something only that member depends on
    # (their user row, a role row, a membership). That member is ejected to
    # personal Tier P delivery — the always-correct path — while everyone
    # else keeps shared delivery; the surface is NOT demoted. Re-admission
    # happens at the member's next render, when their digest matches the
    # shared baseline again. Identity fails closed: no comparable baseline
    # means they stay personal.

    # A change is personal-to-some-member when the promoted scrub render's
    # own read set cannot explain it. Pure read-set evidence — no catalogs.
    #
    # Column refinement resolves the both-shared-and-personal row: a row the
    # scrub render also read (a member's user row shown publicly as an
    # author name) matches the shared read set, but when the write touched
    # only columns the scrub render never read (their admin flag), the
    # shared content cannot have changed for THIS write — it is personal to
    # whoever depends on those columns. Direction of error is safe: missing
    # column evidence on either side falls open to row-level behavior
    # (no extra ejection), and over-recorded columns only over-eject
    # (refresh delivery is never wrong).
    def personal_change?(change)
      return false unless tier_s? && @shared_read_set
      return true unless @shared_read_set.matches?(change)
      changed = change.columns
      shared_columns = @shared_read_set.columns(change.table)
      return false unless changed && shared_columns
      (changed.map(&:to_s) & shared_columns.to_a).empty?
    end

    def member_diverged?(viewer_id)
      viewer_id && @diverged_viewers.include?(viewer_id.to_s)
    end

    def eject_member!(viewer_id, reason:)
      key = viewer_id.to_s
      return if @diverged_viewers.include?(key)
      mutate do
        next if @diverged_viewers.include?(key)
        @diverged_viewers << key
        @evidence.delete(key) # their pre-flip evidence no longer describes them
        Upkeep.stats[:member_ejections] += 1
        instrument("member_diverged", viewer: key, reason: reason)
      end
    end

    def readmit_member!(viewer_id)
      key = viewer_id.to_s
      return unless @diverged_viewers.include?(key)
      mutate do
        next unless @diverged_viewers.delete?(key)
        Upkeep.stats[:member_readmissions] += 1
        instrument("member_readmitted", viewer: key)
      end
    end

    def observe(observation, viewer:, cohort_stream:, ambient:, identity_bound:)
      @cohort_streams << cohort_stream
      @descriptor = observation.descriptor
      instrument("surface_observed", status: @status)
      absorb_observation(observation, viewer, ambient, identity_bound) unless @status == :personal
      persist!
    end

    # Every covering write advances the generation and invalidates digest
    # evidence — digests across a data change are incomparable. Structural
    # island knowledge survives.
    def bump_generation
      mutate do
        @generation += 1
        @evidence = {}
        @generation_mismatches = Set.new
      end
    end

    # Runs on the dispatcher thread. Returns nil when nothing was broadcast.
    def broadcast!
      return nil unless tier_s?
      result = scrubbed_render(at: :broadcast)
      unless result
        persist!
        return nil
      end
      # Dispatch claim, AFTER the render and immediately before transport: a
      # single atomic store-side compare-and-set on the surface's status
      # (UPDATE ... WHERE status IN tier_s). A demotion persisted by any
      # process at any point before the claim wins and the broadcast is
      # dropped. A demotion that commits after the claim can still land
      # while the transport call is in flight — that ordering is converged
      # by the demotion's own cohort refreshes, which are always scheduled
      # after its commit (strict exclusion would mean holding a DB lock
      # across a network call; rejected).
      Upkeep.dispatch_interlock&.call
      unless claim_dispatch!
        instrument("surface_broadcast_dropped", reason: :demoted_at_claim)
        return nil
      end

      # Transport payload limit: an oversized Tier S payload degrades THIS
      # delivery to a refresh (correctness unaffected, sharing steps aside)
      # and warns loudly — a transport cap must never silently disable the
      # optimization. Nothing is persisted: the next write tries again.
      oversized = oversized_payload(result)
      if oversized
        instrument("payload_limit_degrade",
                   size: oversized, limit: Upkeep.payload_limit)
        Upkeep.stats[:payload_limit_degrades] += 1
        @cohort_streams.each { |s| Upkeep.debouncer.schedule(s) }
        return nil
      end

      @shared_read_set = result.read_set if result.read_set
      if @region_addresses.any?
        broadcast_regions(result)
      else
        Turbo::StreamsChannel.broadcast_action_to(
          stream, action: :update, target: @name, html: result.html,
          attributes: generation_stamp
        )
        Upkeep.stats[:surface_broadcasts] += 1
        instrument("surface_broadcast_sent")
        @last_broadcast = { digest: result.digest, generation: @generation }
      end
      converge_diverged_members!
      persist!
      result
    end

    # An ejected member's old page may still hold a live subscription to the
    # surface stream, so a shared payload can transiently land on it. A
    # refresh scheduled AFTER the send re-renders them with their own
    # credentials — refresh is the sole correctness mechanism, and ordering
    # it after the broadcast closes the corrupt-then-nothing race.
    def converge_diverged_members!
      return if @diverged_viewers.empty?
      Upkeep.store.cohorts_for_surface(@name).each do |cohort|
        next unless member_diverged?(cohort.identity)
        Upkeep.debouncer.schedule(cohort.stream)
      end
    end

    private

    # One observation, absorbed step by step; the first step that settles
    # the surface's fate ends the chain.
    def absorb_observation(observation, viewer, ambient, identity_bound)
      if (reason = context_pin_reason(observation, ambient, identity_bound))
        return transition_to_personal(reason)
      end
      return unless viewer&.id # unauthenticated views never count
      viewer_key = viewer.id.to_s
      return if diverged_member_stays?(observation, viewer_key)
      return if divergence_demotes?(observation, viewer_key)
      return if post_broadcast_backstop?(observation, viewer_key)
      @evidence[viewer_key] = {
        digest: observation.digest, role: viewer.role, nodes: observation.node_digests || {}
      }
      try_promote(observation) if @status == :observing
    end

    # Context that disqualifies sharing outright: ambient reads, identity
    # predicates, locals a scrub render could not rebuild.
    def context_pin_reason(observation, ambient, identity_bound)
      return :"ambient_#{ambient.first}" if ambient.any?
      return :identity_predicate if identity_bound
      return :unrefreshable_locals unless observation.descriptor.refreshable?
      nil
    end

    # Ejected member's own render: check for re-admission against the
    # shared baseline (this generation's broadcast, or a peer's evidence).
    # Match -> re-admitted, and the observation counts normally. No match
    # or no comparable baseline -> they stay on personal delivery; their
    # observation must neither poison the evidence pool nor demote the
    # surface (their divergence is known and contained).
    def diverged_member_stays?(observation, viewer_key)
      return false unless tier_s? && member_diverged?(viewer_key)
      return true unless readmission_match?(observation)
      readmit_member!(viewer_key)
      false
    end

    # Cross-viewer divergence: localizable to islands -> record and keep
    # going; unlocalizable (or moving a promoted remainder) -> demote.
    def divergence_demotes?(observation, viewer_key)
      divergent = divergent_addresses(observation, viewer_key)
      fresh = divergent - @personal_nodes.to_a
      return false unless fresh.any? || whole_digest_diverges?(observation, viewer_key, divergent)
      unless localizable?(observation, divergent)
        transition_to_personal(:digest_divergence)
        return true
      end
      if tier_s? && remainder_divergence?(fresh)
        transition_to_personal(:remainder_divergence)
        return true
      end
      @personal_nodes.merge(fresh)
      false
    end

    # Post-broadcast mismatch: the broadcast digests ARE an asymmetric
    # authority (the anonymous truth), so a single viewer disagreeing with
    # them is that VIEWER diverging — eject them, keep the surface shared.
    # This is the backstop for entitlements with no delta-row write signal
    # (constants, time, smuggled state). TWO independent identities
    # disagreeing with the same broadcast is evidence the scrub render
    # itself is wrong — the promotion bar in reverse — and demotes.
    def post_broadcast_backstop?(observation, viewer_key)
      return false unless tier_s? && @last_broadcast && @last_broadcast[:generation] == @generation
      mismatch =
        (shared? && @last_broadcast[:digest] != observation.digest) ||
        (region_shared? && broadcast_remainder_mismatch?(observation))
      return false unless mismatch
      @generation_mismatches << viewer_key
      if @generation_mismatches.size >= 2
        transition_to_personal(:post_broadcast_divergence)
      else
        eject_member!(viewer_key, reason: :post_broadcast_mismatch)
      end
      true
    end

    # Region delivery: for each changed top-level stamped remainder node,
    # either targeted per-row streams (replace a changed iteration instance,
    # remove a vanished one) or a whole-region replace. Island content never
    # appears here — the scrub render is anonymous and islands are excluded
    # from @region_addresses by construction.
    #
    # Per-row targeting engages ONLY when every changed address inside the
    # region is a sound iteration instance already present in the baseline.
    # Everything else — an inserted row (its DOM position cannot be derived
    # from digest evidence, see README), a structural (plain-address)
    # change, an __unsound__ iteration marker, a missing instance text —
    # falls back to replacing the whole region, which is always correct
    # because the region element itself is a stable stamped DOM target.
    # Per-cohort delivery: viewers can hold different page generations (a
    # late registration, a missed delivery), so the scrub render is diffed
    # against EACH cohort's own baseline, and cohorts whose diffs come out
    # identical are grouped so the payload is produced once. A single group
    # — the overwhelmingly common case — is delivered once on the shared
    # surface stream; divergent groups are delivered on the cohorts' own
    # streams. Every delivered cohort's baseline advances to this render's
    # digests. Baseline drift cannot corrupt: a stale baseline only makes
    # the diff LARGER (region payloads are full idempotent content, never
    # deltas), and a viewer whose client missed a delivery converges at the
    # next change to that region or at its next full GET (refresh path).
    def broadcast_regions(result)
      span = region_span_digests(result.node_digests)
      # Ejected members are not part of shared delivery: their cohorts are
      # excluded from the diff groups (converge_diverged_members! refreshes
      # them instead) and their baselines deliberately do not advance — a
      # stale baseline only ever makes a later diff larger, never wrong.
      cohorts = Upkeep.store.cohorts_for_surface(@name)
                           .reject { |c| member_diverged?(c.identity) }
      groups = cohorts.group_by do |cohort|
        region_delivery_plan(result, cohort.baselines&.dig(@name) || {})
      end
      delivered = groups.flat_map do |plan, members|
        deliver_region_group(plan, members, result, span, single: groups.size == 1)
      end
      instrument("surface_region_broadcast_sent", regions: delivered.uniq) if delivered.any?
      @last_broadcast = { digest: result.digest, generation: @generation, nodes: span }
    end

    def deliver_region_group(plan, members, result, span, single:)
      whole, row_replaces, row_removes = plan
      return [] if whole.empty? && row_replaces.empty? && row_removes.empty?
      # A region whose text is unavailable (its bytes came from a warm
      # cached fragment in the scrubbed render) cannot be sent — fail open
      # to a refresh for these cohorts rather than sending nothing.
      unrenderable = whole.reject { |address| result.node_texts[address] }
      return degrade_unrenderable(members, unrenderable) if unrenderable.any?
      streams = single ? [stream] : members.map(&:stream)
      streams.each { |s| send_region_payloads(s, whole, row_replaces, row_removes, result) }
      members.each { |cohort| Upkeep.store.update_baseline(cohort.stream, @name, span) }
      whole + row_replaces + row_removes
    end

    def degrade_unrenderable(members, unrenderable)
      instrument("region_unrenderable_degrade", regions: unrenderable)
      Upkeep.stats[:region_degrades] += 1
      members.each { |cohort| Upkeep.debouncer.schedule(cohort.stream) }
      []
    end

    def send_region_payloads(target_stream, whole, row_replaces, row_removes, result)
      (whole + row_replaces).each do |address|
        Turbo::StreamsChannel.broadcast_action_to(
          target_stream, action: :replace, targets: "[data-upkeep-node='#{address}']",
          html: result.node_texts[address], attributes: generation_stamp
        )
        Upkeep.stats[:region_broadcasts] += 1
        Upkeep.stats[:region_row_replaces] += 1 unless whole.include?(address)
      end
      row_removes.each do |address|
        Turbo::StreamsChannel.broadcast_action_to(
          target_stream, action: :remove, targets: "[data-upkeep-node='#{address}']",
          attributes: generation_stamp
        )
        Upkeep.stats[:region_row_removes] += 1
      end
    end

    # [whole_region_replaces, row_replaces, row_removes]
    def region_delivery_plan(result, previous)
      whole = []
      row_replaces = []
      row_removes = []
      @region_addresses.each do |region|
        action, replaces, removes = region_plan(region, result, previous)
        case action
        when :whole then whole << region
        when :rows
          row_replaces.concat(replaces)
          row_removes.concat(removes)
        end
      end
      [whole, row_replaces, row_removes]
    end

    # One region's delivery shape against one baseline: nil (unchanged),
    # [:whole] (replace the region), or [:rows, replaces, removes]
    # (targeted per-row streams — engages only when every change inside the
    # region is a sound iteration instance already present in the baseline).
    def region_plan(region, result, previous)
      new_span = span_digests(result.node_digests, region)
      old_span = span_digests(previous, region)
      return nil if new_span.empty? || new_span == old_span
      new_inst, new_plain = partition_span(new_span)
      old_inst, old_plain = partition_span(old_span)
      inserted = new_inst.keys - old_inst.keys
      removed = old_inst.keys - new_inst.keys
      updated = (new_inst.keys & old_inst.keys).select { |a| new_inst[a] != old_inst[a] }
      structural = structural_plain_changes(new_plain, old_plain, inserted + removed + updated)
      if inserted.any? || structural.any? || old_span.empty? ||
         updated.any? { |a| result.node_texts[a].nil? }
        [:whole]
      else
        [:rows, updated, removed]
      end
    end

    def partition_span(span)
      span.partition { |a, _| Provenance.instance?(a) }.map(&:to_h)
    end

    # Plain-address changes not explained by any row change (or marked
    # unsound) are structural: the region's shape moved, not just a row.
    def structural_plain_changes(new_plain, old_plain, row_changes)
      (new_plain.keys | old_plain.keys)
        .select { |a| new_plain[a] != old_plain[a] }
        .select do |plain|
          new_plain[plain] == Provenance::UNSOUND || old_plain[plain] == Provenance::UNSOUND ||
            row_changes.none? { |i| ancestor_of_instance?(plain, i) }
        end
    end

    # Every Tier S artifact carries the surface's write generation so the
    # client can enforce the delivery-ordering invariant: never apply a
    # full-page state older than an already-applied region update.
    def generation_stamp
      { "data-upkeep-gen" => @generation }
    end

    def span_digests(digests, region)
      digests.select { |address, _| in_span?(address, region) }
    end

    def region_span_digests(digests)
      digests.select { |address, _| @region_addresses.any? { |r| in_span?(address, r) } }
    end

    def in_span?(address, region)
      base = Provenance.base_of(address)
      base == region || base.start_with?("#{region}.")
    end

    def ancestor_of_instance?(plain, instance)
      base = Provenance.base_of(instance)
      base == plain || base.start_with?("#{plain}.")
    end

    # Addresses where this observation disagrees with any current-generation
    # evidence from OTHER viewers (missing on either side counts).
    def divergent_addresses(observation, viewer_key)
      mine = observation.node_digests || {}
      @evidence.filter_map { |vid, e| e[:nodes] if vid != viewer_key }.flat_map do |theirs|
        (mine.keys | theirs.keys).select { |a| mine[a] != theirs[a] }
      end.uniq
    end

    def whole_digest_diverges?(observation, viewer_key, divergent)
      return false if divergent.any? # already explained at node level
      @evidence.any? { |vid, e| vid != viewer_key && e[:digest] != observation.digest }
    end

    # Divergence is localizable when node tracing exists, the divergent set
    # is a proper subset, and the byte-shared remainder contains at least one
    # stamped (broadcastable) element node.
    def localizable?(observation, divergent)
      nodes = observation.node_digests || {}
      return false if nodes.empty? || divergent.empty?
      remainder = nodes.keys - divergent - @personal_nodes.to_a
      return false if remainder.empty?
      remainder.any? { |a| stamped?(observation.node_texts&.dig(a), a) }
    end

    def remainder_divergence?(fresh_divergence)
      region_span = @region_addresses.to_set
      fresh_divergence.any? do |address|
        region_span.include?(address) ||
          region_span.any? { |region| address.start_with?("#{region}.") }
      end
    end

    # Re-admission authority, strongest first: this generation's broadcast
    # (anonymous truth), else a current-generation peer's evidence. Digests
    # across generations are incomparable, so with neither there is no
    # verdict and the member stays personal (identity fails closed —
    # correct either way, refresh delivery is never wrong).
    def readmission_match?(observation)
      if @last_broadcast && @last_broadcast[:generation] == @generation
        return broadcast_authority_match?(observation)
      end
      peer_evidence_match?(observation)
    end

    def broadcast_authority_match?(observation)
      return @last_broadcast[:digest] == observation.digest if shared?
      !broadcast_remainder_mismatch?(observation)
    end

    def peer_evidence_match?(observation)
      return false if @evidence.empty?
      return @evidence.values.any? { |e| e[:digest] == observation.digest } if shared?
      remainder = (observation.node_digests || {}).keys - @personal_nodes.to_a
      @evidence.values.any? do |e|
        remainder.all? { |a| e[:nodes][a] == observation.node_digests[a] }
      end
    end

    def broadcast_remainder_mismatch?(observation)
      nodes = observation.node_digests || {}
      previous = @last_broadcast[:nodes] || {}
      @region_addresses.any? do |address|
        nodes.key?(address) && previous.key?(address) && nodes[address] != previous[address]
      end
    end

    def stamped?(text, address)
      text.to_s.include?(%(data-upkeep-node="#{address}"))
    end

    # Returns the offending byte size when any payload this delivery would
    # send exceeds the configured transport limit, else nil.
    def oversized_payload(result)
      limit = Upkeep.payload_limit
      return nil unless limit
      payloads =
        if @region_addresses.any?
          @region_addresses.filter_map { |a| result.node_texts[a] }
        else
          [result.html]
        end
      sizes = payloads.map { |p| p.to_s.bytesize }
      worst = sizes.max
      worst && worst > limit ? worst : nil
    end

    def top_level(addresses)
      addresses.reject do |address|
        addresses.any? { |other| other != address && address.start_with?("#{other}.") }
      end.sort
    end

    # Overridden by persistence-backed subclasses.
    def persist! = nil

    # A small, self-contained state mutation. The block must be
    # re-appliable: persistence-backed subclasses retry it against freshly
    # reloaded state when another process persisted concurrently
    # (optimistic lock), so neither side's update is lost.
    def mutate
      yield
      persist!
    end

    # Dispatch claim for the post-render gate. In-memory surfaces are the
    # single copy in a single process, so the in-memory status IS the store
    # status; persistence-backed subclasses perform an atomic
    # compare-and-set on the surface row.
    def claim_dispatch! = tier_s?

    def instrument(event, **payload)
      ActiveSupport::Notifications.instrument(
        "#{event}.upkeep", name: @name, deploy_key: @deploy_key, **payload
      )
    end

    def try_promote(observation)
      return unless promotion_bar_met?
      scrubbed = scrubbed_render(at: :promotion) or return
      if @personal_nodes.empty?
        promote_whole(observation, scrubbed)
      else
        promote_region(observation, scrubbed)
      end
    end

    # The evidence bar: at least two authenticated identities (and two
    # roles when required) with current-generation evidence.
    def promotion_bar_met?
      return false if @evidence.size < 2
      return true unless Upkeep.require_role_diversity
      @evidence.values.map { |e| e[:role] }.uniq.size >= 2
    end

    def scrubbed_render(at:)
      SharedRender.call(@descriptor)
    rescue => e
      instrument("scrubbed_render_failed", error: e.class.name, at: at)
      transition_to_personal(:"scrubbed_render_error_#{e.class.name.demodulize.underscore}")
      nil
    end

    def promote_whole(observation, scrubbed)
      return transition_to_personal(:scrubbed_divergence) unless scrubbed.digest == observation.digest
      @status = :shared
      @shared_read_set = scrubbed.read_set
      # Stamped nodes make even a fully-shared surface deliverable as
      # targeted region replaces (real DOM targets, no dom_id contract);
      # unstamped surfaces keep the whole-partial update. Regions are
      # always PLAIN addresses — per-iteration instances change with the
      # data, so they can be targeted inside a region but never anchor one.
      @region_addresses = top_level(broadcastable_addresses(scrubbed, (scrubbed.node_digests || {}).keys))
      report_unbroadcastable((scrubbed.node_digests || {}).keys) if @region_addresses.any?
      Upkeep.stats[:promotions] += 1
      instrument("surface_promoted", viewers: @evidence.size, regions: @region_addresses)
    end

    # Region promotion: every remainder node must agree across all
    # evidence AND with the anonymous scrubbed render.
    def promote_region(observation, scrubbed)
      remainder = (observation.node_digests || {}).keys - @personal_nodes.to_a
      return unless remainder_agreed?(observation, remainder)
      unless remainder.all? { |a| scrubbed.node_digests[a] == observation.node_digests[a] }
        return transition_to_personal(:scrubbed_divergence)
      end
      broadcastable = broadcastable_addresses(scrubbed, remainder)
      if broadcastable.empty?
        report_unbroadcastable(remainder)
        return transition_to_personal(:no_broadcastable_regions)
      end
      @region_addresses = top_level(broadcastable)
      report_unbroadcastable(remainder)
      @status = :region_shared
      @shared_read_set = scrubbed.read_set
      Upkeep.stats[:region_promotions] += 1
      instrument("surface_promoted", viewers: @evidence.size, region: true, islands: islands)
    end

    def remainder_agreed?(observation, remainder)
      remainder.all? do |address|
        @evidence.values.all? { |e| e[:nodes][address] == observation.node_digests[address] }
      end
    end

    def broadcastable_addresses(scrubbed, addresses)
      addresses.select do |a|
        !Provenance.instance?(a) && stamped?(scrubbed.node_texts[a], a)
      end
    end

    # Unbroadcastable-region detection (evidence time): byte-shared content
    # with no enclosing stamped element — a cache block or control-flow
    # node directly in flow — cannot be targeted by a region broadcast, so
    # writes matching only its dependencies always ride the refresh path.
    # This is an OPERATOR signal explaining why Tier S skips it, never a
    # correctness problem (refresh covers it) and never a request to change
    # templates.
    def report_unbroadcastable(remainder)
      uncovered = remainder.reject do |address|
        Provenance.instance?(address) ||
          @region_addresses.any? { |region| in_span?(address, region) }
      end
      regions = top_level(uncovered)
      return if regions.empty?
      Upkeep.stats[:regions_unbroadcastable] += regions.size
      instrument(
        "region_unbroadcastable",
        reason: :no_enclosing_stamped_element,
        regions: regions.map { |a| { address: a, template: Provenance.template_for(a) } }
      )
    end

    def transition_to_personal(reason)
      was_tier_s = tier_s?
      @status = :personal
      @pin_reason = reason
      Upkeep.stats[:demotions] += 1 if was_tier_s
      Upkeep.stats[:pins] += 1
      instrument(was_tier_s ? "surface_demoted" : "surface_pinned", reason: reason)
      # Drop any pending shared broadcast; converge viewers via refresh.
      Upkeep.debouncer.cancel("surface:#{key}")
      @cohort_streams.each { |s| Upkeep.debouncer.schedule(s) } if was_tier_s
    end

    # --- persistence support -------------------------------------------------

    public

    def state_dump
      {
        "status" => @status.to_s,
        "pin_reason" => @pin_reason&.to_s,
        "generation" => @generation,
        "evidence" => @evidence.transform_values { |e|
          { "digest" => e[:digest], "role" => e[:role], "nodes" => e[:nodes] || {} }
        },
        "cohort_streams" => @cohort_streams.to_a,
        "descriptor" => @descriptor&.to_h,
        "personal_nodes" => @personal_nodes.to_a.sort,
        "region_addresses" => @region_addresses,
        "shared_read_set" => @shared_read_set&.to_h,
        "diverged_viewers" => @diverged_viewers.to_a.sort,
        "generation_mismatches" => @generation_mismatches.to_a.sort,
        "last_broadcast" => @last_broadcast && {
          "digest" => @last_broadcast[:digest],
          "generation" => @last_broadcast[:generation],
          "nodes" => @last_broadcast[:nodes] || {}
        }
      }
    end

    def state_load(h)
      @status = h.fetch("status", "observing").to_sym
      @pin_reason = h["pin_reason"]&.to_sym
      @generation = h.fetch("generation", 0)
      @evidence = h.fetch("evidence", {}).transform_values do |e|
        { digest: e["digest"], role: e["role"], nodes: e.fetch("nodes", {}) }
      end
      @cohort_streams = Set.new(h.fetch("cohort_streams", []))
      @descriptor = h["descriptor"] && Descriptor.from_h(h["descriptor"])
      @personal_nodes = Set.new(h.fetch("personal_nodes", []))
      @region_addresses = h.fetch("region_addresses", [])
      @shared_read_set = h["shared_read_set"] && ReadSet.from_h(h["shared_read_set"])
      @diverged_viewers = Set.new(h.fetch("diverged_viewers", []))
      @generation_mismatches = Set.new(h.fetch("generation_mismatches", []))
      lb = h["last_broadcast"]
      @last_broadcast = lb && {
        digest: lb["digest"], generation: lb["generation"], nodes: lb.fetch("nodes", {})
      }
      self
    end
  end

  class SurfaceRegistry
    def initialize
      @surfaces = {}
      @mutex = Mutex.new
    end

    def lookup(name, deploy_key: Upkeep.deploy_key)
      @mutex.synchronize { @surfaces["#{deploy_key}/#{name}"] }
    end

    def upsert(name, deploy_key: Upkeep.deploy_key)
      @mutex.synchronize do
        @surfaces["#{deploy_key}/#{name}"] ||= Surface.new(name: name, deploy_key: deploy_key)
      end
    end
  end
end
