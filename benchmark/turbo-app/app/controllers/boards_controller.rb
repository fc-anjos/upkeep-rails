class BoardsController < ApplicationController
  before_action :require_login

  def show
    @board = Board.find(params[:id])
    unless @board.accessible_to?(Current.user)
      head :forbidden
      return
    end
    @cards = @board.cards.includes(:creator).order(:created_at)
  end
end
