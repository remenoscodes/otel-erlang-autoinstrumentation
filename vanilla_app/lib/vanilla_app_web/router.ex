defmodule VanillaAppWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VanillaAppWeb do
    pipe_through :api

    get "/items", ItemController, :index
  end
end
