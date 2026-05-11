module M3IdiomHelper
  # Helper-hidden collection render: the M3 idiom under test.
  # The framework observes this call at the read site and derives a stable
  # rtg_* stream id from the call-site + template anchor.
  def comments_for_card(card)
    render partial: "comments/comment", collection: card.comments.order(:created_at), as: :comment
  end

  # Helper-hidden single-record partial render (Idiom #2).
  def card_summary(card)
    render partial: "cards/summary", locals: { card: card }
  end

  # Sibling collections under the same parent card, distinguished by
  # pinned scope (Idiom #6). Distinct call sites produce distinct stream ids
  # so mutations to one scope do not bleed into the other.
  def pinned_comments_for(card)
    render partial: "comments/comment", collection: card.comments.where(pinned: true).order(:created_at), as: :comment
  end

  def recent_comments_for(card)
    render partial: "comments/comment", collection: card.comments.where(pinned: false).order(:created_at), as: :comment
  end

  # Conditional sibling (Idiom #7): two collection renders, second gated by
  # card.show_archived. Per-subscription prior_call_sites storage (Unit 7 v2)
  # is required for the D6 cross-render decline to fire.
  def card_panels(card)
    panels = []
    panels << render(partial: "comments/comment", collection: card.comments.where(pinned: false), as: :comment)
    panels << render(partial: "comments/comment", collection: card.comments.where(pinned: true), as: :comment) if card.show_archived?
    safe_join(panels)
  end
end
