class FeaturedItemsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :update, raise: false

  before_action :require_login
  before_action :set_featured_item

  layout "feed"

  # The "featured item" is whichever FeedItem currently holds the
  # featured slot. We pin it to id=1 in the benchmark so subscribers
  # and writers target the same row; production code would resolve
  # it from a feature flag, an editorial table, or similar.
  def show
  end

  def update
    @featured_item.update!(
      title: params[:title].presence || @featured_item.title,
      body: params[:body].presence || @featured_item.body
    )
    head :ok
  end

  private

  def set_featured_item
    @featured_item = FeedItem.find_by(id: 1) || FeedItem.order(:id).first
  end
end
