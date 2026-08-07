require "json"

module Upkeep
  # The static liveness map behind `rails upkeep:report`: every known page
  # (persisted cohorts grouped by captured path), each surface's tier and
  # pin reason, and every recorded degradation with its reason. Reads the
  # ActiveRecord store only — this is what survives across processes and
  # what a CI step or a terminal can interrogate.
  class Report
    def self.build(deploy_key: Upkeep.deploy_key)
      cohorts = ActiveRecordStore::CohortRow.where(deploy_key: deploy_key)
                                            .order(:id).map { |row| cohort_entry(row) }
      surfaces = ActiveRecordStore::SurfaceRow.where(deploy_key: deploy_key)
                                              .order(:name).map { |row| surface_entry(row) }
      new(deploy_key: deploy_key, cohorts: cohorts, surfaces: surfaces)
    end

    def self.cohort_entry(row)
      read_set = JSON.parse(row.read_set_json)
      degradations = read_set.filter_map do |table, deps|
        reasons = deps.fetch("table_reasons", []).uniq
        [table, reasons] if reasons.any?
      end.to_h
      aggregates = read_set.flat_map do |table, deps|
        deps.fetch("aggregates", []).map { |agg| "#{table} #{ReadSet.aggregate_label(agg)}" }
      end
      {
        path: row.path, stream: row.stream, activated: !row.activated_at.nil?,
        tables: read_set.keys.sort, surfaces: JSON.parse(row.surfaces_json),
        degradations: degradations, aggregates: aggregates.uniq
      }
    end

    TIER_S_STATUSES = %w[shared region_shared].freeze

    def self.surface_entry(row)
      state = row.state_json ? JSON.parse(row.state_json) : {}
      {
        name: row.name, status: row.status,
        tier: TIER_S_STATUSES.include?(row.status) ? "S" : "P",
        pin_reason: state["pin_reason"],
        regions: state.fetch("region_addresses", []),
        diverged_members: state.fetch("diverged_viewers", []).size
      }
    end

    attr_reader :deploy_key, :cohorts, :surfaces

    def initialize(deploy_key:, cohorts:, surfaces:)
      @deploy_key = deploy_key
      @cohorts = cohorts
      @surfaces = surfaces
    end

    def as_json
      { deploy_key: @deploy_key, pages: pages, surfaces: @surfaces }
    end

    # Cohorts grouped by captured path: one entry per known page.
    def pages
      @cohorts.group_by { |c| c[:path] || "(unknown path)" }.map do |path, group|
        {
          path: path,
          cohorts: group.size,
          activated: group.count { |c| c[:activated] },
          tables: group.flat_map { |c| c[:tables] }.uniq.sort,
          surfaces: group.flat_map { |c| c[:surfaces] }.uniq.sort,
          degradations: merged_degradations(group),
          aggregates: group.flat_map { |c| c[:aggregates] }.uniq.sort
        }
      end
    end

    def to_text
      lines = ["upkeep liveness report · deploy #{@deploy_key} · " \
               "#{@cohorts.size} cohorts · #{@surfaces.size} surfaces", ""]
      lines.concat(pages_section)
      lines.concat(surfaces_section)
      lines.join("\n")
    end

    private

    def merged_degradations(group)
      group.each_with_object({}) do |cohort, merged|
        cohort[:degradations].each do |table, reasons|
          merged[table] = ((merged[table] || []) + reasons).uniq
        end
      end
    end

    def pages_section
      return ["PAGES", "  no cohorts registered", ""] if @cohorts.empty?
      ["PAGES"] + pages.flat_map { |page| page_lines(page) } + [""]
    end

    def page_lines(page)
      lines = ["  GET #{page[:path]} — #{page[:cohorts]} " \
               "cohort#{"s" unless page[:cohorts] == 1} (#{page[:activated]} activated)"]
      lines << "    tables: #{page[:tables].join(", ")}"
      lines << "    surfaces: #{page[:surfaces].join(", ")}" if page[:surfaces].any?
      lines << "    aggregates: #{page[:aggregates].join(", ")}" if page[:aggregates].any?
      page[:degradations].each do |table, reasons|
        lines << "    degraded: #{table} → table-level (#{reasons.join(", ")})"
      end
      lines
    end

    def surfaces_section
      return [] if @surfaces.empty?
      ["SURFACES"] + @surfaces.map { |surface| surface_line(surface) }
    end

    def surface_line(surface)
      extras = []
      extras << "#{surface[:regions].size} regions" if surface[:regions].any?
      if surface[:diverged_members].positive?
        extras << "#{surface[:diverged_members]} diverged member(s) on personal refresh"
      end
      line = format("  %-20s %s", surface[:name], tier_label(surface))
      extras.any? ? "#{line} · #{extras.join(" · ")}" : line
    end

    def tier_label(surface)
      case surface[:status]
      when "shared", "region_shared" then "Tier S (#{surface[:status]})"
      when "personal" then "Tier P (pinned: #{surface[:pin_reason] || "unknown"})"
      else "Tier P (candidate, observing)"
      end
    end
  end
end
