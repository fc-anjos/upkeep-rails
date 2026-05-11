# frozen_string_literal: true

class FeedItem < ApplicationRecord
  after_create_commit -> { broadcast_refresh_to "feed_items" }
  after_update_commit -> { broadcast_refresh_to "feed_items" }
end
