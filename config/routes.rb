begin
  require "sidekiq/web"
rescue LoadError
  # Sidekiq Web not available in this runtime
end

Rails.application.routes.draw do
  devise_for :users
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "application#status"

  get "profile" => "users#show", as: :user_profile

  resources :users, only: [:show] do
    collection do
      get "tokens"
      post "tokens", action: :create_token
      delete "tokens/:id", action: :revoke_token, as: :revoke_token
    end
  end

  resources :jobs, only: [:index, :show, :create, :destroy, :update]

  mount Sidekiq::Web => "/sidekiq" if defined?(Sidekiq::Web)
end
