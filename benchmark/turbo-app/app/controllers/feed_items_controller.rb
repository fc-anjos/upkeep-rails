# frozen_string_literal: true

class FeedItemsController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  # Identity-free update mirror of the upkeep-app FeedItems resource so
  # `memory_ceiling/shared_feed_churn` can issue the same write mix to
  # both apps.
  def update
    item = FeedItem.find(params[:id])
    item.update!(
      title: params[:title].presence || item.title,
      body: params[:body].presence || item.body
    )
    head :ok
  end
end
