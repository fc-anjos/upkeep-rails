class FeedItemsController < ApplicationController
  skip_before_action :set_current_user, raise: false
  skip_before_action :verify_authenticity_token, raise: false

  # Identity-free update for the shared anonymous feed. Drives the
  # subscribed-row writer mode of `memory_ceiling/shared_feed_churn`:
  # an update on a row already inside the rendered window invalidates
  # an existing fragment, exercising the byte-equality proof gate.
  def update
    item = FeedItem.find(params[:id])
    item.update!(
      title: params[:title].presence || item.title,
      body: params[:body].presence || item.body
    )
    head :ok
  end
end
