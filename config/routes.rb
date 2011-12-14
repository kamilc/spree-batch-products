Rails.application.routes.draw do
  namespace :admin do
    resources :product_datasheets do
    end
  end
end
