class CardsController < ApplicationController
  before_action :require_login

  def create
    @board = Board.find(params[:board_id])
    @board.cards.create!(title: params[:card][:title], creator: Current.user)
    head :created
  end

  def update
    @board = Board.find(params[:board_id])
    @card = @board.cards.find(params[:id])
    @card.update!(card_params)
    head :ok
  end

  private

  def card_params
    params.require(:card).permit(:title, :status)
  end
end
