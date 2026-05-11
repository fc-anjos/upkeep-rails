class MessagesController < ApplicationController
  before_action :require_login

  def create
    @room = Room.find(params[:room_id])
    @room.messages.create!(body: params[:message][:body], user: Current.user)
    head :created
  end
end
