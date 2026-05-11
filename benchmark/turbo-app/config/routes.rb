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

  get "feed", to: "feed#show"
  post "feed", to: "feed#create"
  resources :feed_items, only: :update

  resource :featured_item, only: %i[show update]

  root to: redirect("/rooms/1")
end
