module M3IdiomHelper
  # Helper-hidden collection render: the render call lives behind a helper
  # method while Rails still resolves the collection boundary at runtime.
  def comments_for_card(card)
    render partial: "comments/comment", collection: card.comments.order(:created_at), as: :comment
  end

  # Helper-hidden single-record partial render.
  def card_summary(card)
    render partial: "cards/summary", locals: { card: card }
  end

  # Sibling collections under the same parent card, distinguished by pinned
  # scope and separate helper call sites.
  def pinned_comments_for(card)
    render partial: "comments/comment", collection: card.comments.where(pinned: true).order(:created_at), as: :comment
  end

  def recent_comments_for(card)
    render partial: "comments/comment", collection: card.comments.where(pinned: false).order(:created_at), as: :comment
  end

  # Conditional sibling: two collection renders, with the second gated by
  # card.show_archived.
  def card_panels(card)
    panels = []
    panels << render(partial: "comments/comment", collection: card.comments.where(pinned: false), as: :comment)
    panels << render(partial: "comments/comment", collection: card.comments.where(pinned: true), as: :comment) if card.show_archived?
    safe_join(panels)
  end
end
