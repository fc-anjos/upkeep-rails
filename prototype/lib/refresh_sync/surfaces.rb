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
  #                               observation diverges (viewer-vs-viewer in a
  #                               generation, or viewer-vs-last-broadcast in
  #                               the same generation). Demotion drops the
  #                               pending broadcast and refreshes cohorts.
  #   :personal   Terminal for this deploy key. Tier P forever.
  #
  # Identity fails closed; freshness fails open.
  Descriptor = Struct.new(:name, :partial, :locals, keyword_init: true) do
    def tables
      locals.values.grep(ActiveRecord::Relation).map { |r| r.klass.table_name }
    end

    def refreshable?
      locals.values.all? do |v|
        v.is_a?(ActiveRecord::Relation) || v.is_a?(Numeric) || v.is_a?(String) ||
          v.is_a?(Symbol) || v == true || v == false || v.nil?
      end
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
      @evidence = Hash.new { |h, k| h[k] = {} } # generation => {viewer_id => {digest:, role:}}
      @cohort_streams = Set.new
      @last_broadcast = nil
    end

    def key = "#{@deploy_key}/#{@name}"
    def stream = "refresh_sync:surface:#{key}"
    def shared? = @status == :shared
    def tables = @descriptor ? @descriptor.tables : []

    def observe(observation, viewer:, cohort_stream:, ambient:, identity_bound:)
      @cohort_streams << cohort_stream
      @descriptor = observation.descriptor
      return if @status == :personal

      if ambient.any?
        transition_to_personal(:"ambient_#{ambient.first}")
        return
      end
      if identity_bound
        transition_to_personal(:identity_predicate)
        return
      end
      unless observation.descriptor.refreshable?
        transition_to_personal(:unrefreshable_locals)
        return
      end
      return unless viewer&.id # unauthenticated views never count as evidence

      gen = @evidence[@generation]
      other = gen.find { |vid, e| vid != viewer.id && e[:digest] != observation.digest }
      if other
        transition_to_personal(:digest_divergence)
        return
      end
      if shared? && @last_broadcast && @last_broadcast[:generation] == @generation &&
         @last_broadcast[:digest] != observation.digest
        transition_to_personal(:post_broadcast_divergence)
        return
      end

      gen[viewer.id] = { digest: observation.digest, role: viewer.role }
      try_promote(observation.digest) if @status == :observing
    end

    def bump_generation
      @generation += 1
    end

    # Runs on the dispatcher thread. Returns nil when nothing was broadcast.
    def broadcast!
      return nil unless shared?
      begin
        result = SharedRender.call(@descriptor)
      rescue => e
        transition_to_personal(:"scrubbed_render_error_#{e.class.name.demodulize.underscore}")
        return nil
      end
      Turbo::StreamsChannel.broadcast_action_to(
        stream, action: :update, target: @name, html: result.html
      )
      RefreshSync.stats[:surface_broadcasts] += 1
      @last_broadcast = { digest: result.digest, generation: @generation }
      result
    end

    private

    def try_promote(digest)
      viewers = @evidence[@generation]
      return if viewers.size < 2
      if RefreshSync.require_role_diversity && viewers.values.map { |e| e[:role] }.uniq.size < 2
        return
      end

      scrubbed =
        begin
          SharedRender.call(@descriptor)
        rescue => e
          transition_to_personal(:"scrubbed_render_error_#{e.class.name.demodulize.underscore}")
          return
        end
      if scrubbed.digest == digest
        @status = :shared
        RefreshSync.stats[:promotions] += 1
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
      # Drop any pending shared broadcast; converge viewers via refresh.
      RefreshSync.debouncer.cancel("surface:#{key}")
      @cohort_streams.each { |s| RefreshSync.debouncer.schedule(s) } if was_shared
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
