# frozen_string_literal: true

class FeaturedItemsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :update, raise: false

  before_action :require_login
  before_action :set_featured_item

  # Mirror of the upkeep-app FeaturedItems resource so the
  # `render_dedup/mixed_region_feed_ivar_compare` workload runs
  # apples-to-apples. Turbo broadcasts a refresh on every FeedItem
  # update via the `after_update_commit` callback on the model;
  # subscribers receive the refresh ping and re-fetch the page.
  # Upkeep proves byte-equality at the relay and ships compact ops
  # without a re-render — the comparison surfaces the wire-bytes and
  # RSS gap between the two delivery shapes.
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
