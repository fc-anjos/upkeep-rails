Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  mount BenchMetrics::Endpoint, at: "/bench/metrics" if BenchMetrics.enabled?

  post "sessions", to: "sessions#create"
  delete "session", to: "sessions#destroy"

  resources :rooms, only: :show do
    resources :messages, only: :create
  end

  resources :boards, only: :show do
    resources :cards, only: [ :create, :update ]
  end

  # Shared feed: anonymous row output with one stable subscription
  # identity across subscribers. Per-row updates flow through the
  # FeedItems resource so the byte-equality proof gate sees an
  # invalidation on a fragment already in the rendered window.
  get "feed", to: "feed#show"
  post "feed", to: "feed#create"
  resources :feed_items, only: :update

  # Signed feed: the same row stream rendered through Current-dependent
  # output so fallback fanout is exercised under load.
  get "signed_feed", to: "feed#signed"
  post "signed_feed", to: "feed#signed_create"

  # Mixed feed: stable row fields, Current-dependent output, and
  # controller-hydrated transient state in one outer fragment.
  get "mixed_feed", to: "feed#mixed"
  post "mixed_feed/:id", to: "feed#mixed_update"

  # The featured item is a singular resource: there is exactly one
  # featured FeedItem at a time. The page renders it via an ivar so the
  # `view_assigns`-derived binding path that SlotStateCapture resolves
  # at request time is exercised end-to-end.
  resource :featured_item, only: %i[show update]

  # M3 idiom fixtures.
  get  "m3/helper_hidden_collection/:card_id", to: "m3_idioms#helper_hidden_collection", as: :m3_helper_hidden_collection
  post "m3/helper_hidden_collection/:card_id/comments", to: "m3_idioms#create_comment", as: :m3_create_comment

  get   "m3/helper_hidden_partial/:card_id", to: "m3_idioms#helper_hidden_partial", as: :m3_helper_hidden_partial
  patch "m3/helper_hidden_partial/:card_id", to: "m3_idioms#update_card_title", as: :m3_update_card_title

  get  "m3/render_in_bare/:card_id", to: "m3_idioms#render_in_bare", as: :m3_render_in_bare

  get  "m3/polymorphic/:card_id", to: "m3_idioms#polymorphic", as: :m3_polymorphic
  post "m3/polymorphic/:card_id/comments", to: "m3_idioms#create_polymorphic_comment", as: :m3_create_polymorphic_comment

  get  "m3/sibling_collections/:card_id", to: "m3_idioms#sibling_collections", as: :m3_sibling_collections
  post "m3/sibling_collections/:card_id/pinned", to: "m3_idioms#create_pinned_comment", as: :m3_create_pinned_comment
  post "m3/sibling_collections/:card_id/recent", to: "m3_idioms#create_recent_comment", as: :m3_create_recent_comment

  get   "m3/conditional_sibling/:card_id", to: "m3_idioms#conditional_sibling", as: :m3_conditional_sibling
  patch "m3/conditional_sibling/:card_id/toggle", to: "m3_idioms#toggle_show_archived", as: :m3_toggle_show_archived

  root to: redirect("/rooms/1")
end
