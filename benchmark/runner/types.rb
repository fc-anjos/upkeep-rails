# frozen_string_literal: true

module Upkeep
  module Benchmark
    module Runner
      class WorkloadError < StandardError; end

      Workload = Data.define(
        :key,
        :needs_turbo,
        :route_script,
        :post_label,
        :top_level,
        :vus,
        :capacity_gate
      )
    end
  end
end
