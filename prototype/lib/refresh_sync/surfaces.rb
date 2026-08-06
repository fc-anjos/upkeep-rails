require "digest"
require "set"

module RefreshSync
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
      locals.values.grep(ActiveRecord::Relation).map { |r| r.klass.table_name }
    end

    def refreshable?
      locals.values.all? do |v|
        if v.is_a?(ActiveRecord::Relation)
          # Persistable+re-runnable only when the where clause is a faithful
          # simple hash (rebuildable as klass.where(hash) in any process).
          v.where_clause.ast.nil? || simple_relation?(v)
        else
          v.is_a?(Numeric) || v.is_a?(String) || v.is_a?(Symbol) ||
            v == true || v == false || v.nil?
        end
      end
    end

    def simple_relation?(rel)
      flat = rel.where_clause.ast.is_a?(Arel::Nodes::And) ? rel.where_clause.ast.children : [rel.where_clause.ast].compact
      rel.where_values_hash.size == flat.size
    end

    def to_h
      serialized = locals.transform_values do |v|
        if v.is_a?(ActiveRecord::Relation)
          { "__relation__" => v.klass.name, "where" => v.where_values_hash }
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
                :personal_nodes, :region_addresses

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
    end

    def key = "#{@deploy_key}/#{@name}"
    def stream = "refresh_sync:surface:#{key}"
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

    def observe(observation, viewer:, cohort_stream:, ambient:, identity_bound:)
      @cohort_streams << cohort_stream
      @descriptor = observation.descriptor
      instrument("surface_observed", status: @status)
      return persist! if @status == :personal

      if ambient.any?
        transition_to_personal(:"ambient_#{ambient.first}")
        return persist!
      end
      if identity_bound
        transition_to_personal(:identity_predicate)
        return persist!
      end
      unless observation.descriptor.refreshable?
        transition_to_personal(:unrefreshable_locals)
        return persist!
      end
      return persist! unless viewer&.id # unauthenticated views never count

      viewer_key = viewer.id.to_s
      divergent = divergent_addresses(observation, viewer_key)
      fresh_divergence = divergent - @personal_nodes.to_a

      if fresh_divergence.any? || whole_digest_diverges?(observation, viewer_key, divergent)
        if localizable?(observation, divergent)
          # Divergence confined to islands with a byte-shared stamped
          # remainder: record the personal nodes and keep observing (or, on
          # a promoted surface, demote only if the REMAINDER moved).
          if tier_s? && remainder_divergence?(fresh_divergence)
            transition_to_personal(:remainder_divergence)
            return persist!
          end
          @personal_nodes.merge(fresh_divergence)
        else
          transition_to_personal(:digest_divergence)
          return persist!
        end
      end

      if tier_s? && @last_broadcast && @last_broadcast[:generation] == @generation
        if shared? && @last_broadcast[:digest] != observation.digest
          transition_to_personal(:post_broadcast_divergence)
          return persist!
        end
        if region_shared? && broadcast_remainder_mismatch?(observation)
          transition_to_personal(:post_broadcast_divergence)
          return persist!
        end
      end

      @evidence[viewer_key] = {
        digest: observation.digest, role: viewer.role, nodes: observation.node_digests || {}
      }
      try_promote(observation) if @status == :observing
      persist!
    end

    # Every covering write advances the generation and invalidates digest
    # evidence — digests across a data change are incomparable. Structural
    # island knowledge survives.
    def bump_generation
      @generation += 1
      @evidence = {}
      persist!
    end

    # Runs on the dispatcher thread. Returns nil when nothing was broadcast.
    def broadcast!
      return nil unless tier_s?
      begin
        result = SharedRender.call(@descriptor)
      rescue => e
        instrument("scrubbed_render_failed", error: e.class.name, at: :broadcast)
        transition_to_personal(:"scrubbed_render_error_#{e.class.name.demodulize.underscore}")
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
      RefreshSync.dispatch_interlock&.call
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
                   size: oversized, limit: RefreshSync.payload_limit)
        RefreshSync.stats[:payload_limit_degrades] += 1
        @cohort_streams.each { |s| RefreshSync.debouncer.schedule(s) }
        return nil
      end

      if @region_addresses.any?
        broadcast_regions(result)
      else
        Turbo::StreamsChannel.broadcast_action_to(
          stream, action: :update, target: @name, html: result.html
        )
        RefreshSync.stats[:surface_broadcasts] += 1
        instrument("surface_broadcast_sent")
        @last_broadcast = { digest: result.digest, generation: @generation }
      end
      persist!
      result
    end

    private

    # Region delivery: replace each changed top-level stamped remainder node.
    # Island content never appears here — the scrub render is anonymous and
    # islands are excluded from @region_addresses by construction.
    def broadcast_regions(result)
      previous = @last_broadcast && @last_broadcast[:generation] != @generation ? @last_broadcast[:nodes] : @last_broadcast&.dig(:nodes)
      changed = @region_addresses.select do |address|
        result.node_digests[address] && result.node_digests[address] != previous&.dig(address)
      end
      # A changed region whose text is unavailable (its bytes came from a
      # warm cached fragment in the scrubbed render) cannot be sent — fail
      # open to a refresh for everyone rather than sending nothing.
      unrenderable = changed.reject { |address| result.node_texts[address] }
      if unrenderable.any?
        instrument("region_unrenderable_degrade", regions: unrenderable)
        RefreshSync.stats[:region_degrades] += 1
        @cohort_streams.each { |s| RefreshSync.debouncer.schedule(s) }
        return
      end
      changed.each do |address|
        Turbo::StreamsChannel.broadcast_action_to(
          stream,
          action: :replace,
          targets: "[data-rs-node='#{address}']",
          html: result.node_texts[address]
        )
        RefreshSync.stats[:region_broadcasts] += 1
      end
      instrument("surface_region_broadcast_sent", regions: changed) if changed.any?
      @last_broadcast = {
        digest: result.digest,
        generation: @generation,
        nodes: result.node_digests.slice(*@region_addresses)
      }
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

    def broadcast_remainder_mismatch?(observation)
      nodes = observation.node_digests || {}
      previous = @last_broadcast[:nodes] || {}
      @region_addresses.any? do |address|
        nodes.key?(address) && previous.key?(address) && nodes[address] != previous[address]
      end
    end

    def stamped?(text, address)
      text.to_s.include?(%(data-rs-node="#{address}"))
    end

    # Returns the offending byte size when any payload this delivery would
    # send exceeds the configured transport limit, else nil.
    def oversized_payload(result)
      limit = RefreshSync.payload_limit
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

    # Dispatch claim for the post-render gate. In-memory surfaces are the
    # single copy in a single process, so the in-memory status IS the store
    # status; persistence-backed subclasses perform an atomic
    # compare-and-set on the surface row.
    def claim_dispatch! = tier_s?

    def instrument(event, **payload)
      ActiveSupport::Notifications.instrument(
        "#{event}.refresh_sync", name: @name, deploy_key: @deploy_key, **payload
      )
    end

    def try_promote(observation)
      return if @evidence.size < 2
      if RefreshSync.require_role_diversity && @evidence.values.map { |e| e[:role] }.uniq.size < 2
        return
      end

      scrubbed =
        begin
          SharedRender.call(@descriptor)
        rescue => e
          instrument("scrubbed_render_failed", error: e.class.name, at: :promotion)
          transition_to_personal(:"scrubbed_render_error_#{e.class.name.demodulize.underscore}")
          return
        end

      if @personal_nodes.empty?
        if scrubbed.digest == observation.digest
          @status = :shared
          # Stamped nodes make even a fully-shared surface deliverable as
          # targeted region replaces (real DOM targets, no dom_id contract);
          # unstamped surfaces keep the whole-partial update.
          @region_addresses = top_level(
            (scrubbed.node_digests || {}).keys.select { |a| stamped?(scrubbed.node_texts[a], a) }
          )
          RefreshSync.stats[:promotions] += 1
          instrument("surface_promoted", viewers: @evidence.size, regions: @region_addresses)
        else
          transition_to_personal(:scrubbed_divergence)
        end
        return
      end

      # Region promotion: every remainder node must agree across all
      # evidence AND with the anonymous scrubbed render.
      remainder = (observation.node_digests || {}).keys - @personal_nodes.to_a
      agreed = remainder.all? do |address|
        @evidence.values.all? { |e| e[:nodes][address] == observation.node_digests[address] }
      end
      return unless agreed
      unless remainder.all? { |a| scrubbed.node_digests[a] == observation.node_digests[a] }
        transition_to_personal(:scrubbed_divergence)
        return
      end

      broadcastable = remainder.select { |a| stamped?(scrubbed.node_texts[a], a) }
      if broadcastable.any?
        @region_addresses = top_level(broadcastable)
        @status = :region_shared
        RefreshSync.stats[:region_promotions] += 1
        instrument("surface_promoted", viewers: @evidence.size, region: true, islands: islands)
      else
        transition_to_personal(:no_broadcastable_regions)
      end
    end

    def transition_to_personal(reason)
      was_tier_s = tier_s?
      @status = :personal
      @pin_reason = reason
      RefreshSync.stats[:demotions] += 1 if was_tier_s
      RefreshSync.stats[:pins] += 1
      instrument(was_tier_s ? "surface_demoted" : "surface_pinned", reason: reason)
      # Drop any pending shared broadcast; converge viewers via refresh.
      RefreshSync.debouncer.cancel("surface:#{key}")
      @cohort_streams.each { |s| RefreshSync.debouncer.schedule(s) } if was_tier_s
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

    def lookup(name, deploy_key: RefreshSync.deploy_key)
      @mutex.synchronize { @surfaces["#{deploy_key}/#{name}"] }
    end

    def upsert(name, deploy_key: RefreshSync.deploy_key)
      @mutex.synchronize do
        @surfaces["#{deploy_key}/#{name}"] ||= Surface.new(name: name, deploy_key: deploy_key)
      end
    end
  end
end
