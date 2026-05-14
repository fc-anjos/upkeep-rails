# frozen_string_literal: true

# Fail-fast on parent-tracking failures. When a partial renders without
# locals_map_store entries from its parent, fragment + region wrapping
# silently no-ops and per-region dedup is structurally impossible. Default
# `:warn` is too quiet for benchmark workloads; the smoke gate hides the
# regression behind correct-looking output.
Rails.application.config.upkeep.refused_boundary_behavior = :raise
