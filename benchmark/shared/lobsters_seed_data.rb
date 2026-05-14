# frozen_string_literal: true

require "bcrypt"
require "securerandom"

module LobstersSeedData
  PASSWORD = "benchpass123"

  module_function

  def call
    reset_tables
    inactive_user
    users = create_users
    categories = create_categories
    tags = create_tags(categories)
    stories = create_stories(users, tags)
    create_comments(users, stories)
    create_votes(users, stories)
    print_summary
  end

  def reset_tables
    conn = ActiveRecord::Base.connection

    conn.disable_referential_integrity do
      (conn.tables - %w[schema_migrations ar_internal_metadata]).each do |table|
        conn.execute("DELETE FROM #{conn.quote_table_name(table)}")
        reset_sequence(table) if sqlite_sequence?
      end
    end
  end

  def reset_sequence(table)
    ActiveRecord::Base.connection.execute(
      "DELETE FROM sqlite_sequence WHERE name = #{ActiveRecord::Base.connection.quote(table)}"
    )
  end

  def sqlite_sequence?
    ActiveRecord::Base.connection.table_exists?("sqlite_sequence")
  end

  def inactive_user
    User.create!(
      username: "inactive-user",
      email: "inactive-user@bench.test",
      password: PASSWORD,
      password_confirmation: PASSWORD,
      password_reset_token: "reset-inactive"
    )
  end

  def create_users
    count = Integer(ENV.fetch("LOBSTERS_NUM_USERS", 200))
    count.times.map do |i|
      User.create!(
        username: "user#{i + 1}",
        email: "user#{i + 1}@bench.test",
        password: PASSWORD,
        password_confirmation: PASSWORD,
        password_reset_token: "reset-user#{i + 1}",
        karma: 100,
        created_at: 120.days.ago
      )
    end
  end

  def create_categories
    %w[Development Operations Culture].map do |name|
      Category.create!(category: name)
    end
  end

  def create_tags(categories)
    [
      [ "ruby", categories[0] ],
      [ "rails", categories[0] ],
      [ "sqlite", categories[1] ],
      [ "performance", categories[1] ],
      [ "meta", categories[2] ]
    ].map do |tag_name, category|
      Tag.create!(tag: tag_name, category: category, description: "#{tag_name} benchmark tag")
    end
  end

  def create_stories(users, tags)
    count = Integer(ENV.fetch("LOBSTERS_NUM_STORIES", 250))
    count.times.map do |i|
      story = Story.new(
        user: users[i % users.length],
        title: "Benchmark story #{i + 1}",
        url: "https://example.test/stories/#{i + 1}",
        description: "Benchmark story #{i + 1} body",
        tags_a: [ tags[i % tags.length].tag ],
        created_at: (count - i).minutes.ago
      )
      story.save!
      story.update_column(:short_id, story_short_id(i))
      story
    end
  end

  def story_short_id(index)
    format("b%05d", index + 1)
  end

  def create_comments(users, stories)
    comments_per_story = Integer(ENV.fetch("LOBSTERS_COMMENTS_PER_STORY", 3))
    stories.each_with_index do |story, story_index|
      comments_per_story.times do |i|
        Comment.create!(
          user: users[(story_index + i) % users.length],
          story: story,
          comment: "Benchmark comment #{story_index + 1}-#{i + 1}"
        )
      end
    end
  end

  def create_votes(users, stories)
    stories.each_with_index do |story, _story_index|
      users.first(10).each do |user|
        next if user == story.user

        Vote.vote_thusly_on_story_or_comment_for_user_because(
          1, story.id, nil, user.id, nil, false
        )
      end
    end
  end

  def print_summary
    puts "Seeded Lobsters benchmark: #{User.count} users, #{Story.count} stories, #{Comment.count} comments, #{Vote.count} votes"
  end
end
