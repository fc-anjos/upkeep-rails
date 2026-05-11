# frozen_string_literal: true

class FeedController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :create, raise: false

  def show
    @items = FeedItem.order(id: :desc).limit(50)
  end

  def create
    FeedItem.create!(title: params[:title].to_s, body: params[:body].to_s)
    head :created
  end
end
