class M3IdiomsController < ApplicationController
  # No authentication required — pages are anonymous so Playwright specs
  # don't need session cookies. CSRF skipped on mutation endpoints.
  skip_before_action :set_current_user
  skip_before_action :verify_authenticity_token,
    only: %i[create_comment update_card_title create_polymorphic_comment
             create_pinned_comment create_recent_comment toggle_show_archived]

  def helper_hidden_collection
    @card = Card.find(params[:card_id])
  end

  def helper_hidden_partial
    @card = Card.find(params[:card_id])
  end

  def render_in_bare
    @card = Card.find(params[:card_id])
  end

  def polymorphic
    @card = Card.find(params[:card_id])
  end

  def sibling_collections
    @card = Card.find(params[:card_id])
  end

  def conditional_sibling
    @card = Card.find(params[:card_id])
  end

  # Mutation: update a card's title (used by helper_hidden_partial).
  def update_card_title
    @card = Card.find(params[:card_id])
    @card.update!(title: params[:title].to_s.presence || "updated")
    head :ok
  end

  # Mutation: create a plain comment (used by helper_hidden_collection and render_in_bare).
  def create_comment
    @card = Card.find(params[:card_id])
    @card.comments.create!(body: params[:body].to_s.presence || "comment")
    head :created
  end

  # Mutation: create a StaffComment or GuestComment for the polymorphic idiom.
  def create_polymorphic_comment
    @card = Card.find(params[:card_id])
    klass = params[:kind] == "staff" ? StaffComment : GuestComment
    klass.create!(card: @card, body: params[:body].to_s.presence || "comment")
    head :created
  end

  # Mutation: create a pinned comment for the sibling_collections idiom.
  def create_pinned_comment
    @card = Card.find(params[:card_id])
    @card.comments.create!(body: params[:body].to_s.presence || "comment", pinned: true)
    head :created
  end

  # Mutation: create a recent (unpinned) comment for the sibling_collections idiom.
  def create_recent_comment
    @card = Card.find(params[:card_id])
    @card.comments.create!(body: params[:body].to_s.presence || "comment", pinned: false)
    head :created
  end

  # Mutation: toggle show_archived for the conditional_sibling idiom.
  def toggle_show_archived
    @card = Card.find(params[:card_id])
    @card.update!(show_archived: !@card.show_archived)
    head :ok
  end
end
