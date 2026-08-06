require_relative "test_helper"

class DebugTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_dump_read_set
    visit_board(@board1)
    cohort = RefreshSync.store.instance_variable_get(:@cohorts).values.last
    cohort.read_set.tables.each do |table, deps|
      puts "#{table}: ids=#{deps.ids.to_a.inspect} preds=#{deps.predicates.inspect} table_reasons=#{deps.table_reasons.inspect}"
    end
  end
end
