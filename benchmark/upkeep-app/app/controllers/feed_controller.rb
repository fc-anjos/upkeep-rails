class FeedController < ApplicationController
  # `#show` and `#create` are anonymous and identity-free, powering the
  # `classifier/identity_free_feed` workload. The signed and mixed
  # surfaces require Current.user so benchmark rows can exercise
  # subscriber-keyed rendering beside shared record output.
  skip_before_action :set_current_user, only: %i[show create], raise: false
  skip_before_action :verify_authenticity_token, only: %i[show create signed_create mixed_update], raise: false

  layout "feed"

  def show
    @items = FeedItem.order(id: :desc).limit(50)
  end

  def create
    FeedItem.create!(title: params[:title].to_s, body: params[:body].to_s)
    head :created
  end

  def signed
    return redirect_to(root_path) unless Current.user

    @items = FeedItem.order(id: :desc).limit(50)
    render :signed
  end

  def signed_create
    return head(:unauthorized) unless Current.user

    FeedItem.create!(title: params[:title].to_s, body: params[:body].to_s)
    head :created
  end

  def mixed
    return redirect_to(root_path) unless Current.user

    @items = FeedItem.order(id: :desc).limit(50)
  end

  def mixed_update
    return head(:unauthorized) unless Current.user

    item = FeedItem.find(params[:id])
    item.update!(
      title: params[:title].presence || item.title,
      body: params[:body].presence || item.body
    )
    head :ok
  end
end
