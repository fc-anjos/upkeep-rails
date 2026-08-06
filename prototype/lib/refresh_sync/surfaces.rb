require "digest"
require "set"

module RefreshSync
  # A "surface" is a named shareable region: a partial + captured locals.
  # Promotion state machine, per (surface name, deploy key):
  #
  #   :observing  Tier P. Accumulating evidence. Transitions:
  #                 -> :personal  ambient read / identity predicate /
  #                               unrefreshable locals / digest divergence /
  #                               scrubbed-render divergence or error
  #                 -> :shared    >=2 authenticated identities (and >=2 roles
  #                               when role diversity is required) with
  #                               byte-identical digests in the same write
  #                               generation, AND a scrubbed render whose
  #                               digest matches theirs
  #   :shared     Tier S. One scrubbed render broadcast per write window.
  #                 -> :personal  scrubbed render raises, or any later
  #                               observation diverges. Demotion drops the
  #                               pending broadcast and refreshes cohorts.
  #   :personal   Terminal for this deploy key.
  #
  # Evidence is kept for the CURRENT write generation only; every covering
  # write clears it (digests across a data change are incomparable).
  # Identity fails closed; freshness fails open.
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

  SurfaceObservation = Struct.new(:descriptor, :digest, keyword_init: true)
  Viewer = Struct.new(:id, :role, keyword_init: true)

  class Surface
    attr_reader :name, :deploy_key, :status, :pin_reason, :descriptor,
                :cohort_streams, :generation, :last_broadcast

    def initialize(name:, deploy_key:)
      @name = name
      @deploy_key = deploy_key
      @status = :observing
      @pin_reason = nil
      @generation = 0
      @evidence = {} # current generation only: viewer_id(String) => {digest:, role:}
      @cohort_streams = Set.new
      @last_broadcast = nil # {digest:, generation:}
    end

    def key = "#{@deploy_key}/#{@name}"
    def stream = "refresh_sync:surface:#{key}"
    def shared? = @status == :shared
    def tables = @descriptor ? @descriptor.tables : []

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
      if @evidence.any? { |vid, e| vid != viewer_key && e[:digest] != observation.digest }
        transition_to_personal(:digest_divergence)
        return persist!
      end
      if shared? && @last_broadcast && @last_broadcast[:generation] == @generation &&
         @last_broadcast[:digest] != observation.digest
        transition_to_personal(:post_broadcast_divergence)
        return persist!
      end

      @evidence[viewer_key] = { digest: observation.digest, role: viewer.role }
      try_promote(observation.digest) if @status == :observing
      persist!
    end

    # Every covering write advances the generation and invalidates digest
    # evidence — digests across a data change are incomparable.
    def bump_generation
      @generation += 1
      @evidence = {}
      persist!
    end

    # Runs on the dispatcher thread. Returns nil when nothing was broadcast.
    def broadcast!
      return nil unless shared?
      begin
        result = SharedRender.call(@descriptor)
      rescue => e
        instrument("scrubbed_render_failed", error: e.class.name, at: :broadcast)
        transition_to_personal(:"scrubbed_render_error_#{e.class.name.demodulize.underscore}")
        persist!
        return nil
      end
      Turbo::StreamsChannel.broadcast_action_to(
        stream, action: :update, target: @name, html: result.html
      )
      RefreshSync.stats[:surface_broadcasts] += 1
      instrument("surface_broadcast_sent")
      @last_broadcast = { digest: result.digest, generation: @generation }
      persist!
      result
    end

    private

    # Overridden by persistence-backed subclasses.
    def persist! = nil

    def instrument(event, **payload)
      ActiveSupport::Notifications.instrument(
        "#{event}.refresh_sync", name: @name, deploy_key: @deploy_key, **payload
      )
    end

    def try_promote(digest)
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
      if scrubbed.digest == digest
        @status = :shared
        RefreshSync.stats[:promotions] += 1
        instrument("surface_promoted", viewers: @evidence.size)
      else
        transition_to_personal(:scrubbed_divergence)
      end
    end

    def transition_to_personal(reason)
      was_shared = shared?
      @status = :personal
      @pin_reason = reason
      RefreshSync.stats[:demotions] += 1 if was_shared
      RefreshSync.stats[:pins] += 1
      instrument(was_shared ? "surface_demoted" : "surface_pinned", reason: reason)
      # Drop any pending shared broadcast; converge viewers via refresh.
      RefreshSync.debouncer.cancel("surface:#{key}")
      @cohort_streams.each { |s| RefreshSync.debouncer.schedule(s) } if was_shared
    end

    # --- persistence support -------------------------------------------------

    public

    def state_dump
      {
        "status" => @status.to_s,
        "pin_reason" => @pin_reason&.to_s,
        "generation" => @generation,
        "evidence" => @evidence.transform_values { |e| { "digest" => e[:digest], "role" => e[:role] } },
        "cohort_streams" => @cohort_streams.to_a,
        "descriptor" => @descriptor&.to_h,
        "last_broadcast" => @last_broadcast && {
          "digest" => @last_broadcast[:digest], "generation" => @last_broadcast[:generation]
        }
      }
    end

    def state_load(h)
      @status = h.fetch("status", "observing").to_sym
      @pin_reason = h["pin_reason"]&.to_sym
      @generation = h.fetch("generation", 0)
      @evidence = h.fetch("evidence", {}).transform_values do |e|
        { digest: e["digest"], role: e["role"] }
      end
      @cohort_streams = Set.new(h.fetch("cohort_streams", []))
      @descriptor = h["descriptor"] && Descriptor.from_h(h["descriptor"])
      lb = h["last_broadcast"]
      @last_broadcast = lb && { digest: lb["digest"], generation: lb["generation"] }
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
