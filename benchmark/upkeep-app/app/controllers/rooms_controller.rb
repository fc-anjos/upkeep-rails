class RoomsController < ApplicationController
  before_action :require_login

  def show
    @room = Room.find(params[:id])
    @messages = @room.messages.includes(:user).order(:created_at)
  end
end
