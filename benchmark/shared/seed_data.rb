# frozen_string_literal: true

# Shared seed data for benchmark apps (upkeep-app and turbo-app).
#
# Usage from db/seeds.rb:
#   require_relative "../../shared/seed_data"
#   BenchmarkSeed.call
#
# ENV:
#   NUM_USERS — number of users to create (default: 200)

module BenchmarkSeed
  PASSWORD = "benchpass123"

  def self.call
    reset_tables
    users = create_users
    create_rooms_and_memberships(users)
    create_board_and_cards(users)
    create_feed_items
    print_summary
  end

  def self.reset_tables
    conn = ActiveRecord::Base.connection
    %w[feed_items cards accesses boards messages room_memberships rooms users].each do |table|
      next unless conn.table_exists?(table)
      conn.execute("DELETE FROM #{table}")
      conn.execute("DELETE FROM sqlite_sequence WHERE name='#{table}'")
    end
  end

  def self.create_users
    num_users = (ENV["NUM_USERS"] || 200).to_i
    puts "Creating #{num_users} users..."

    digest = BCrypt::Password.create(PASSWORD, cost: BCrypt::Engine::MIN_COST)
    now = Time.current

    rows = Array.new(num_users) do |i|
      { name: "User #{i + 1}", email: "user#{i + 1}@bench.test", password_digest: digest, created_at: now, updated_at: now }
    end
    User.insert_all(rows)
    User.order(:id).to_a
  end

  def self.create_rooms_and_memberships(users)
    now = Time.current
    rooms = Array.new(2) do |i|
      Room.create!(name: "Room #{i + 1}")
    end

    rooms.each do |room|
      memberships = users.map { |u| { room_id: room.id, user_id: u.id, created_at: now, updated_at: now } }
      RoomMembership.insert_all(memberships)

      10.times do |i|
        Message.create!(body: "Message #{i + 1} in #{room.name}", room: room, user: users[i % users.size])
      end
    end
  end

  def self.create_board_and_cards(users)
    now = Time.current
    board = Board.create!(name: "Benchmark Board", creator: users[0])

    accesses = users.map { |u| { board_id: board.id, user_id: u.id, created_at: now, updated_at: now } }
    Access.insert_all(accesses)

    statuses = %w[todo in_progress done]
    20.times do |i|
      Card.create!(
        title: "Card #{i + 1}",
        status: statuses[i % statuses.size],
        board: board,
        creator: users[i % users.size]
      )
    end

    create_per_user_boards(users, statuses)
  end

  # Per-user boards used by the render_dedup/isolated workload: each VU
  # subscribes to (and writes to) their own board, so the dedup key
  # (subscription_url, fragment_id, locals_digest) is unique per VU and
  # the relay's coalescer cannot fold renders across subs. Off by
  # default to keep the chat/board scenarios cheap; opt-in via
  # LOW_SHARING_BOARDS=N.
  def self.create_per_user_boards(users, statuses)
    n = Integer(ENV["LOW_SHARING_BOARDS"] || 0)
    return if n.zero?

    n = [ n, users.size ].min
    now = Time.current

    n.times do |i|
      owner = users[i]
      board = Board.create!(name: "Solo board #{i + 1}", creator: owner)
      Access.insert_all([ { board_id: board.id, user_id: owner.id, created_at: now, updated_at: now } ])
      3.times do |j|
        Card.create!(
          title: "Solo #{i + 1}-#{j + 1}",
          status: statuses[j % statuses.size],
          board: board,
          creator: owner
        )
      end
    end
  end

  # Seed the classifier/identity_free_feed workload's feed. Small fixed
  # set — the workload exercises invalidation fan-out, not cardinality.
  # Skipped gracefully on apps that don't have the `feed_items` table
  # (turbo-app).
  def self.create_feed_items
    return unless defined?(FeedItem) && FeedItem.table_exists?

    rows = Array.new(10) do |i|
      { title: "Item #{i + 1}", body: "Shared feed body #{i + 1}", created_at: Time.current, updated_at: Time.current }
    end
    FeedItem.insert_all(rows)
  end

  def self.print_summary
    puts "Seeded: #{User.count} users, #{Room.count} rooms, #{Message.count} messages, " \
         "#{Board.count} board, #{Card.count} cards, #{Access.count} accesses"
  end
end
