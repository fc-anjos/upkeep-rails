class CardCountSummary
  def initialize(card)
    @card = card
  end

  def render_in(view_context)
    count = @card.comments.count
    view_context.tag.div(
      "Card #{@card.id} has #{count} comments",
      data: { testid: "card-count-summary", card_id: @card.id },
      id: "card-count-summary-#{@card.id}"
    )
  end

  def format = :html
end
