# frozen_string_literal: true

require "json"
require "time"

module LobstersWorkloadManifest
  module_function

  def call(path:)
    stories = Story.order(:id).limit(50).pluck(:id, :short_id)
    comments = Comment.order(:id).limit(100).pluck(:id, :short_id, :story_id)
    users = User.where.not(username: "inactive-user").order(:id).limit(200).pluck(:id, :email)

    payload = {
      generated_at: Time.now.utc.iso8601,
      stories: stories.map { |id, short_id| { id: id, short_id: short_id } },
      comments: comments.map { |id, short_id, story_id| { id: id, short_id: short_id, story_id: story_id } },
      users: users.map { |id, email| { id: id, email: email } }
    }

    File.write(path, JSON.pretty_generate(payload))
    payload
  end
end
