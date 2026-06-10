# frozen_string_literal: true

require "test_helper"

class FreshScopeStory < ActiveRecord::Base
  self.table_name = "fresh_scope_stories"

  has_many :comments, class_name: "FreshScopeComment", foreign_key: :story_id
end

class FreshScopeComment < ActiveRecord::Base
  self.table_name = "fresh_scope_comments"

  belongs_to :story, class_name: "FreshScopeStory", optional: true
end

class FreshScopeReaction < ActiveRecord::Base
  self.table_name = "fresh_scope_reactions"

  belongs_to :reactable, polymorphic: true, optional: true
end

class FreshRecordScopeTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :fresh_scope_stories, force: true do |table|
        table.string :title, null: false
      end

      create_table :fresh_scope_comments, force: true do |table|
        table.references :story
        table.string :body
      end

      create_table :fresh_scope_reactions, force: true do |table|
        table.references :reactable, polymorphic: true
        table.string :emoji
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def test_association_built_record_records_scoped_wildcard_dependency
    story = FreshScopeStory.create!(title: "Plan")

    dependency = capture_fresh_dependency(story.comments.build, :body)

    assert_nil dependency.key.fetch(:id)
    assert_equal({ "story_id" => story.id }, dependency.key.fetch(:scope))
  end

  def test_scoped_dependency_only_matches_creates_carrying_the_owning_foreign_key
    story = FreshScopeStory.create!(title: "Plan")
    other_story = FreshScopeStory.create!(title: "Backlog")

    dependency = capture_fresh_dependency(story.comments.build, :body)

    matching_create = commit_change(story.comments.create!(body: "Yes"))
    other_create = commit_change(other_story.comments.create!(body: "No"))

    assert dependency.matches_change?(matching_create)
    refute dependency.matches_change?(other_create)
  end

  def test_scoped_dependency_keeps_matching_updates_that_do_not_carry_the_foreign_key
    story = FreshScopeStory.create!(title: "Plan")
    other_story = FreshScopeStory.create!(title: "Backlog")
    other_comment = other_story.comments.create!(body: "Old")

    dependency = capture_fresh_dependency(story.comments.build, :body)

    other_comment.update!(body: "New")
    update_change = commit_change(other_comment)

    assert dependency.matches_change?(update_change)
  end

  def test_scoped_dependency_only_matches_destroys_carrying_the_owning_foreign_key
    story = FreshScopeStory.create!(title: "Plan")
    other_story = FreshScopeStory.create!(title: "Backlog")
    comment = story.comments.create!(body: "Yes")
    other_comment = other_story.comments.create!(body: "No")

    dependency = capture_fresh_dependency(story.comments.build, :body)

    comment.destroy!
    other_comment.destroy!

    assert dependency.matches_change?(commit_change(comment))
    refute dependency.matches_change?(commit_change(other_comment))
  end

  def test_bare_new_record_keeps_wildcard_matching
    story = FreshScopeStory.create!(title: "Plan")
    other_story = FreshScopeStory.create!(title: "Backlog")

    dependency = capture_fresh_dependency(FreshScopeComment.new, :body)

    assert_nil dependency.key[:scope]
    assert dependency.matches_change?(commit_change(story.comments.create!(body: "Yes")))
    assert dependency.matches_change?(commit_change(other_story.comments.create!(body: "No")))
  end

  def test_polymorphic_association_without_concrete_owner_keeps_wildcard_matching
    story = FreshScopeStory.create!(title: "Plan")

    dependency = capture_fresh_dependency(FreshScopeReaction.new, :emoji)

    assert_nil dependency.key[:scope]
    assert dependency.matches_change?(
      commit_change(FreshScopeReaction.create!(reactable: story, emoji: "+1"))
    )
  end

  def test_polymorphic_association_with_concrete_owner_scopes_matching
    story = FreshScopeStory.create!(title: "Plan")
    other_story = FreshScopeStory.create!(title: "Backlog")

    dependency = capture_fresh_dependency(FreshScopeReaction.new(reactable: story), :emoji)

    assert_equal(
      { "reactable_type" => "FreshScopeStory", "reactable_id" => story.id },
      dependency.key.fetch(:scope)
    )
    assert dependency.matches_change?(
      commit_change(FreshScopeReaction.create!(reactable: story, emoji: "+1"))
    )
    refute dependency.matches_change?(
      commit_change(FreshScopeReaction.create!(reactable: other_story, emoji: "+1"))
    )
  end

  def test_serialization_round_trip_preserves_the_scope
    story = FreshScopeStory.create!(title: "Plan")
    other_story = FreshScopeStory.create!(title: "Backlog")

    dependency = capture_fresh_dependency(story.comments.build, :body)
    restored = Upkeep::Dependencies.from_h(JSON.parse(JSON.generate(dependency.to_h)))

    assert_equal dependency.cache_key, restored.cache_key
    assert restored.matches_change?(commit_change(story.comments.create!(body: "Yes")))
    refute restored.matches_change?(commit_change(other_story.comments.create!(body: "No")))
  end

  private

  def capture_fresh_dependency(record, attribute)
    _, recorder = Upkeep::Runtime::Observation.capture_request do
      record.public_send(attribute)
    end

    deps = recorder.graph.dependencies_for(Upkeep::Runtime::Recorder::REQUEST_NODE_ID)
    dependency = deps.find do |dep|
      dep.is_a?(Upkeep::Dependencies::ActiveRecordAttribute) &&
        dep.key.fetch(:table) == record.class.table_name &&
        dep.key.fetch(:attribute) == attribute.to_s
    end

    refute_nil dependency
    dependency
  end

  def commit_change(record)
    Upkeep::Runtime::ChangeEvents.active_record_commit(record)
  end
end
