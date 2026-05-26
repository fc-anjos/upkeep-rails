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
    assert_equal [
      {
        table: "query_analysis_cards",
        column: "status",
        operator: "eq",
        values: ["open"]
      }
    ], analysis.predicates
    assert dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["status"]))
    refute dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["title"]))
  end

  def test_structural_in_predicate_with_string_values_records_proven_columns
    analysis = analyze(QueryAnalysisCard.where(status: ["open", "done"]).order(:position))
    dependency = dependency_for(analysis)

    assert_equal :columns, analysis.coverage
    assert_equal({
      "query_analysis_cards" => %w[id position status]
    }, analysis.table_columns)
    assert_equal [
      {
        table: "query_analysis_cards",
        column: "status",
        operator: "in",
        values: ["open", "done"]
      }
    ], analysis.predicates
    assert dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: ["status"],
        old_values: { "status" => "open" },
        new_values: { "status" => "archived" }
      )
    )
    refute dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: ["status"],
        old_values: { "status" => "archived" },
        new_values: { "status" => "closed" }
      )
    )
  end

  def test_arel_in_node_with_string_values_records_proven_columns
    cards = QueryAnalysisCard.arel_table
    analysis = analyze(QueryAnalysisCard.where(cards[:status].in(["open", "done"])))

    assert_equal :columns, analysis.coverage
    assert_equal [
      {
        table: "query_analysis_cards",
        column: "status",
        operator: "in",
        values: ["open", "done"]
      }
    ], analysis.predicates
  end

  def test_arel_matches_node_records_proven_column_without_opaque_pattern
    cards = QueryAnalysisCard.arel_table
    analysis = analyze(QueryAnalysisCard.where(cards[:title].matches("%Plan%")))
    dependency = dependency_for(analysis)

    assert_equal :columns, analysis.coverage
    assert_equal({
      "query_analysis_cards" => %w[id title]
    }, analysis.table_columns)
    assert_empty analysis.predicates
    assert dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["title"]))
    refute dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["status"]))
  end

  def test_arel_named_function_records_expression_columns_without_treating_function_name_as_sql
    cards = QueryAnalysisCard.arel_table
    lower_title = Arel::Nodes::NamedFunction.new("LOWER", [cards[:title]])
    lower_pattern = Arel::Nodes::NamedFunction.new("LOWER", [Arel::Nodes.build_quoted("%plan%")])
    analysis = analyze(QueryAnalysisCard.where(lower_title.matches(lower_pattern)))
    dependency = dependency_for(analysis)

    assert_equal :columns, analysis.coverage
    assert_equal({
      "query_analysis_cards" => %w[id title]
    }, analysis.table_columns)
    assert dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["title"]))
    refute dependency.matches_change?(change(table: "query_analysis_cards", attributes: ["status"]))
  end

  def test_collection_dependency_uses_predicate_values_to_filter_updates
    analysis = analyze(QueryAnalysisCard.where(status: "open").order(:position))
    dependency = dependency_for(analysis)

    assert dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: ["status"],
        old_values: { "status" => "open" },
        new_values: { "status" => "done" }
      )
    )
    assert dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: ["status"],
        old_values: { "status" => "done" },
        new_values: { "status" => "open" }
      )
    )
    refute dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: ["status"],
        old_values: { "status" => "done" },
        new_values: { "status" => "archived" }
      )
    )
  end

  def test_collection_dependency_uses_predicate_values_to_filter_creates_and_deletes
    analysis = analyze(QueryAnalysisCard.where(status: "open").order(:position))
    dependency = dependency_for(analysis)

    assert dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: %w[id status title],
        type: "create",
        new_values: { "status" => "open" }
      )
    )
    refute dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: %w[id status title],
        type: "create",
        new_values: { "status" => "done" }
      )
    )
    assert dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: %w[id status title],
        type: "destroy",
        old_values: { "status" => "open" }
      )
    )
    refute dependency.matches_change?(
      change(
        table: "query_analysis_cards",
        attributes: %w[id status title],
        type: "destroy",
        old_values: { "status" => "done" }
      )
    )
  end

  def test_opaque_predicate_raises_relation_error
    error = assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) do
      analyze(QueryAnalysisCard.where("status = ?", "open").order(:position))
    end

    assert_includes error.message, "cannot make this Active Record relation reactive"
    assert_includes error.message, "raw SQL predicate"
    assert_includes error.message, "Rewrite raw SQL predicates"
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

  def test_raw_join_raises_opaque_relation_error
    relation = QueryAnalysisCard
      .joins("INNER JOIN query_analysis_authors ON query_analysis_authors.id = query_analysis_cards.author_id")
      .where("query_analysis_authors.name = ?", "Ada")

    error = assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) { analyze(relation) }

    assert_includes error.message, "cannot make this Active Record relation reactive"
    assert_includes error.message, "raw SQL join"
    assert_includes error.message, "Rewrite raw SQL joins"
  end

  def test_write_observation_can_describe_opaque_relation_against_the_model_table
    analysis = analyze(
      QueryAnalysisCard.joins("INNER JOIN query_analysis_authors ON query_analysis_authors.id = query_analysis_cards.author_id"),
      opaque_table_policy: :allow_table
    )

    assert_equal :tables, analysis.coverage
    assert_equal ["query_analysis_cards"], analysis.tables
  end

  def test_write_observation_can_describe_opaque_predicate_against_the_model_table
    analysis = analyze(
      QueryAnalysisCard.where("status = ?", "open"),
      opaque_table_policy: :allow_table
    )

    assert_equal :tables, analysis.coverage
    assert_equal ["query_analysis_cards"], analysis.tables
  end

  def test_collection_dependency_rejects_table_coverage
    error = assert_raises(ArgumentError) do
      Upkeep::Dependencies::ActiveRecordCollection.new(
        primary_table: "query_analysis_cards",
        table_columns: { "query_analysis_cards" => ["id"] },
        coverage: :tables,
        sql: QueryAnalysisCard.all.to_sql
      )
    end

    assert_includes error.message, "collection dependencies require proven column coverage"
  end

  def test_appendability_comes_from_relation_shape
    assert analyze(QueryAnalysisCard.where(status: "open").order(:id)).appendable?
    refute analyze(QueryAnalysisCard.where("status = ?", "open").order(:id), opaque_table_policy: :allow_table).appendable?
    refute analyze(QueryAnalysisCard.where(status: "open").limit(10)).appendable?
    assert_equal 10, analyze(QueryAnalysisCard.where(status: "open").limit(10)).limit_value
    refute analyze(QueryAnalysisCard.distinct.where(status: "open")).appendable?
    refute analyze(QueryAnalysisCard.group(:status)).appendable?
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
      replay: Upkeep::Replay::Collection.new(
        partial: "query_analysis_cards/card",
        controller_class: nil,
        collection: Upkeep::Replay::ActiveRecordRelationValue.new(
          model: "QueryAnalysisCard",
          sql: QueryAnalysisCard.order(:id).to_sql,
          primary_key: QueryAnalysisCard.primary_key,
          appendable: true,
          limit_value: nil,
          predicates: [],
          member_ids: [card.id.to_s]
        ),
        options: {}
      )
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

  def analyze(relation, **options)
    Upkeep::ActiveRecordQuery.analyze(relation, **options)
  end

  def dependency_for(analysis)
    Upkeep::Dependencies::ActiveRecordCollection.new(
      primary_table: analysis.primary_table,
      table_columns: analysis.table_columns,
      coverage: analysis.coverage,
      sql: analysis.sql,
      predicates: analysis.predicates
    )
  end

  def change(table:, attributes:, type: "update", old_values: {}, new_values: {})
    {
      type: type,
      table: table,
      changed_attributes: attributes,
      old_values: old_values,
      new_values: new_values
    }
  end
end
