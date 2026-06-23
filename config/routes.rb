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
  root "application#sso"

  get "profile" => "users#show", as: :user_profile

  resources :users, only: [:show] do
    collection do
      get "tokens"
      post "tokens", action: :create_token
      delete "tokens/:id", action: :revoke_token, as: :revoke_token
    end
  end

  # resources :jobs, only: [:index, :show, :create, :destroy, :update]

  namespace :api do
    resources :jobs, only: [:index, :show, :create, :destroy, :update]
    get "status" => "application#status"
  end

  namespace :admin do

    resources :users, only: [:index, :create, :destroy, :update] do
      member do
        get "tokens"
        post "tokens", action: :create_token
        delete "tokens/:id", action: :revoke_token, as: :revoke_token
      end
    end

    resources :jobs, only: [:show, :index, :destroy, :update] do
      member do
        get "cancel"
      end
    end

    get :settings, to: "settings#index"
    get :toggle_server_status, to: "settings#toggle_server_status"

  end

  mount Sidekiq::Web => "/queue" if defined?(Sidekiq::Web)
end
