# frozen_string_literal: true

require "active_record"
require "minitest/autorun"
require_relative "sqlglot_active_record_query"
require_relative "../../../lib/upkeep/active_record_query"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:authors) { |t| t.string :name }
  create_table(:cards) do |t|
    t.references :author
    t.string :title
    t.string :status
    t.integer :position
  end
  create_table(:efforts) do |t|
    t.references :card
    t.string :status
  end
end

class SpikeAuthor < ActiveRecord::Base
  self.table_name = "authors"
  has_many :cards, class_name: "SpikeCard", foreign_key: :author_id
end

class SpikeCard < ActiveRecord::Base
  self.table_name = "cards"
  belongs_to :author, class_name: "SpikeAuthor", optional: true
end

class SqlglotActiveRecordQueryTest < Minitest::Test
  def test_matches_arel_for_structured_filter_and_order
    relation = SpikeCard.where(status: "open").order(:position)

    assert_equal arel_projection(relation), sqlglot_projection(relation)
  end

  def test_matches_arel_for_structured_join
    relation = SpikeCard.joins(:author).where(authors: { name: "Ada" }).order(:position)

    assert_equal arel_projection(relation), sqlglot_projection(relation)
  end

  def test_handles_raw_predicate_that_arel_decoder_rejects
    relation = SpikeCard.where("lower(cards.title) LIKE ?", "%plan%").order("cards.position DESC")

    assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) do
      Upkeep::ActiveRecordQuery.analyze(relation)
    end

    analysis = analyze(relation)
    assert_equal({"cards" => %w[id position title]}, analysis.table_columns)
    assert_empty analysis.warnings
  end

  def test_handles_raw_join_that_arel_decoder_rejects
    relation = SpikeCard
      .joins("INNER JOIN authors ON authors.id = cards.author_id")
      .where("authors.name = ?", "Ada")

    assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) do
      Upkeep::ActiveRecordQuery.analyze(relation)
    end

    analysis = analyze(relation)
    assert_equal({"authors" => %w[id name], "cards" => %w[author_id id]}, analysis.table_columns)
    assert_equal ["authors.id=cards.author_id"], analysis.equality_edges
  end

  def test_correlated_exists_records_inner_and_outer_dependencies
    relation = SpikeCard.where(<<~SQL.squish)
      EXISTS (
        SELECT 1 FROM efforts
        WHERE efforts.card_id = cards.id
          AND efforts.status = 'active'
      )
    SQL

    analysis = analyze(relation)
    assert_equal(
      {"cards" => %w[id], "efforts" => %w[card_id status]},
      analysis.table_columns
    )
    assert_equal ["cards.id=efforts.card_id"], analysis.equality_edges
    assert_includes analysis.predicates, {
      table: "efforts", column: "status", operator: "eq", values: ["active"]
    }
  end

  def test_cte_is_not_reported_as_a_physical_table
    sql = <<~SQL.squish
      WITH active_efforts AS (
        SELECT card_id FROM efforts WHERE status = 'active'
      )
      SELECT cards.* FROM cards
      INNER JOIN active_efforts ON active_efforts.card_id = cards.id
    SQL
    relation = SpikeCard.from("(#{sql}) AS cards")

    analysis = analyze(relation)
    assert_equal %w[cards efforts], analysis.tables
    refute_includes analysis.tables, "active_efforts"
  end

  def test_limit_distinct_and_group_shape_come_from_sql_ast
    assert analyze(SpikeCard.all).appendable?
    refute analyze(SpikeCard.limit(10)).appendable?
    assert_equal 10, analyze(SpikeCard.limit(10)).limit_value
    refute analyze(SpikeCard.distinct).appendable?
    refute analyze(SpikeCard.group(:status)).appendable?
  end

  def test_or_predicates_preserve_dnf_groups
    base = SpikeCard.where(position: 1)
    relation = base.where(status: nil).or(base.where.not(status: "closed"))

    assert_equal [
      {table: "cards", column: "position", operator: "eq", values: [1], group: 0},
      {table: "cards", column: "status", operator: "eq", values: [nil], group: 0},
      {table: "cards", column: "position", operator: "eq", values: [1], group: 1},
      {table: "cards", column: "status", operator: "not_eq", values: ["closed"], group: 1}
    ].sort_by(&:to_s), analyze(relation).predicates.sort_by(&:to_s)
  end

  private

  def analyze(relation)
    SqlglotActiveRecordQuery.analyze(relation)
  end

  def arel_projection(relation)
    result = Upkeep::ActiveRecordQuery.analyze(relation)
    [result.table_columns, result.predicates]
  end

  def sqlglot_projection(relation)
    result = analyze(relation)
    [result.table_columns, result.predicates]
  end
end
