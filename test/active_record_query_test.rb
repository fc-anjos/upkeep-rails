# frozen_string_literal: true

require "test_helper"

class QueryAnalysisAuthor < ActiveRecord::Base
  self.table_name = "query_analysis_authors"

  has_many :cards, class_name: "QueryAnalysisCard", foreign_key: :author_id
end

class QueryAnalysisCard < ActiveRecord::Base
  self.table_name = "query_analysis_cards"

  belongs_to :author, class_name: "QueryAnalysisAuthor", optional: true
end

class QueryAnalysisPerson < ActiveRecord::Base
  self.table_name = "query_analysis_people"

  belongs_to :manager, class_name: "QueryAnalysisPerson", optional: true
end

class ActiveRecordQueryTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :query_analysis_authors, force: true do |table|
        table.string :name, null: false
      end

      create_table :query_analysis_cards, force: true do |table|
        table.references :author
        table.string :title, null: false
        table.string :status, null: false
        table.integer :position, null: false
      end

      create_table :query_analysis_comments, force: true do |table|
        table.string :body, null: false
      end

      create_table :query_analysis_people, force: true do |table|
        table.references :manager
        table.string :name, null: false
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def test_structural_relation_records_proven_columns
    analysis = analyze(QueryAnalysisCard.where(status: "open").order(:position))
    dependency = dependency_for(analysis)

    assert_equal :columns, analysis.coverage
    assert_equal({
      "query_analysis_cards" => %w[id position status]
    }, analysis.table_columns)
    assert dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["status"]))
    refute dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["title"]))
  end

  def test_opaque_predicate_uses_known_table_coverage
    analysis = analyze(QueryAnalysisCard.where("status = ?", "open").order(:position))
    dependency = dependency_for(analysis)

    assert_equal :tables, analysis.coverage
    assert_equal ["query_analysis_cards"], analysis.tables
    assert dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["title"]))
    refute dependency.matches_change?(change(table: "query_analysis_authors", attributes: ["name"]))
  end

  def test_association_join_records_joined_table_columns
    analysis = analyze(
      QueryAnalysisCard.joins(:author).where(query_analysis_authors: { name: "Ada" }).order(:position)
    )
    dependency = dependency_for(analysis)

    assert_equal :columns, analysis.coverage
    assert_equal %w[id name], analysis.table_columns.fetch("query_analysis_authors")
    assert_equal %w[author_id id position], analysis.table_columns.fetch("query_analysis_cards")
    assert dependency.matches_change?(change(table: "query_analysis_authors", attributes: ["name"]))
    refute dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["title"]))
  end

  def test_aliased_self_join_columns_map_to_the_real_table
    analysis = analyze(QueryAnalysisPerson.joins(:manager).where(manager: { name: "Ada" }))
    dependency = dependency_for(analysis)

    assert_equal :columns, analysis.coverage
    assert_equal %w[id manager_id name], analysis.table_columns.fetch("query_analysis_people")
    refute_includes analysis.table_columns.keys, "manager"
    assert dependency.matches_change?(change(table: "query_analysis_people", attributes: ["name"]))
    assert dependency.matches_change?(change(table: "query_analysis_people", attributes: ["manager_id"]))
  end

  def test_raw_join_uses_database_coverage
    analysis = analyze(
      QueryAnalysisCard
        .joins("INNER JOIN query_analysis_authors ON query_analysis_authors.id = query_analysis_cards.author_id")
        .where("query_analysis_authors.name = ?", "Ada")
    )
    dependency = dependency_for(analysis)
    recorder = Upkeep::Runtime::Recorder.new
    recorder.with_frame("frame:raw-join", kind: "render_site") { recorder.record_dependency(dependency) }
    store = Upkeep::Subscriptions::Store.new
    store.register(subscriber_id: "subscriber", recorder: recorder)

    assert_equal :database, analysis.coverage
    assert_nil dependency.collection_lookup_tables
    assert_equal 1, store.reverse_index.entries_for([change(table: "query_analysis_comments", attributes: ["body"])]).size
  end

  def test_appendability_comes_from_relation_shape
    assert analyze(QueryAnalysisCard.where(status: "open").order(:id)).appendable?
    refute analyze(QueryAnalysisCard.where("status = ?", "open").order(:id)).appendable?
    refute analyze(QueryAnalysisCard.where(status: "open").limit(10)).appendable?
    refute analyze(QueryAnalysisCard.distinct.where(status: "open")).appendable?
    refute analyze(QueryAnalysisCard.group(:status).having("count(*) > 1")).appendable?
  end

  def test_append_recipe_only_handles_creates_for_the_collection_model_table
    card = QueryAnalysisCard.create!(title: "Plan", status: "open", position: 1)
    recipe = Upkeep::Replay::Recipe.new(
      kind: :render_site,
      frame_id: "frame:cards",
      target_kind: "render_site",
      target_id: "cards",
      template: "query_analysis_cards/card",
      runtime: "rails",
      replay: {
        type: "collection",
        partial: "query_analysis_cards/card",
        collection: {
          type: "active_record_relation",
          model: "QueryAnalysisCard",
          sql: QueryAnalysisCard.order(:id).to_sql,
          primary_key: QueryAnalysisCard.primary_key,
          appendable: true,
          member_ids: [card.id.to_s]
        }
      }
    )

    append = Upkeep::Invalidation::CollectionAppend.build(
      recipe: recipe,
      change: change(table: "query_analysis_authors", attributes: ["id"], type: "create_or_update").merge(id: card.id)
    )

    assert_nil append
  end

  def test_string_update_all_records_all_table_columns
    QueryAnalysisCard.create!(title: "Plan", status: "open", position: 1)

    Upkeep::Runtime::ChangeLog.reset
    QueryAnalysisCard.where("status = ?", "open").update_all("title = 'Renamed'")

    event = Upkeep::Runtime::ChangeLog.events.fetch(0)
    assert_equal "bulk_update", event.fetch(:type)
    assert_equal :tables, event.fetch(:predicate_coverage).to_sym
    assert_equal QueryAnalysisCard.column_names.sort, event.fetch(:changed_attributes).sort
    assert_equal ["id", "author_id", "title", "status", "position"].sort, event.fetch(:changed_attributes).sort
  end

  private

  def analyze(relation)
    Upkeep::ActiveRecordQuery.analyze(relation)
  end

  def dependency_for(analysis)
    Upkeep::Dependencies::ActiveRecordCollection.new(
      primary_table: analysis.primary_table,
      table_columns: analysis.table_columns,
      coverage: analysis.coverage,
      sql: analysis.sql
    )
  end

  def change(table:, attributes:, type: "update")
    {
      type: type,
      table: table,
      changed_attributes: attributes
    }
  end
end
