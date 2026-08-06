module Upkeep
  # Fragment caching hides reads: on a cache hit the block never runs, so
  # the queries inside are unobserved and their dependencies silently drop
  # out of the page's read set — the under-invalidation direction, which
  # breaks the product promise. Fix: on a miss, capture the read-set slice
  # produced inside the block and store it NEXT TO the fragment (same cache
  # store, digest-coupled key); on a hit, replay the stored slice into the
  # active Recording so the cohort's dependencies are identical either way.
  #
  # Coupling guarantee: if the side entry is missing (evicted independently
  # of the fragment), the fragment is expired so the block runs live and
  # both entries are rewritten together. Fail open — never a cached
  # fragment without its read set.
  module FragmentCache
    SIDE_KEY_PREFIX = "upkeep:fragment:".freeze

    module CacheHelperObserver
      def cache(name = {}, options = {}, &block)
        recording = Recording.current
        unless recording && controller.respond_to?(:perform_caching) && controller.perform_caching
          return super
        end

        fragment_name = cache_fragment_name(name, **options.slice(:skip_digest, :digest_path))
        side_key = SIDE_KEY_PREFIX + ActiveSupport::Cache.expand_cache_key(fragment_name)

        stored = Rails.cache.read(side_key)
        if stored
          recording.read_set.absorb(stored.fetch("read_set", stored))
          # Warm fragments never execute their nodes; replay their digests
          # so per-node evidence sees the (byte-identical) cached content.
          stored.fetch("node_digests", {}).each do |address, digest|
            recording.prov.inject_digest(address, digest)
          end
          Upkeep.stats[:fragment_readset_replays] += 1
          super
        else
          # No read set on record: force the block to run live even if the
          # fragment itself is still warm.
          controller.expire_fragment(fragment_name)
          recording.read_set.begin_slice
          prov_marker = recording.prov.segment_marker
          result = super
          slice = recording.read_set.end_slice
          Rails.cache.write(
            side_key,
            {
              "read_set" => slice.to_h,
              "node_digests" => recording.prov.node_digests_since(prov_marker)
            },
            **options.slice(:expires_in)
          )
          Upkeep.stats[:fragment_readset_captures] += 1
          result
        end
      end
    end

    def self.install!
      ActiveSupport.on_load(:action_view) do
        ActionView::Base.prepend(CacheHelperObserver)
      end
    end
  end
end
