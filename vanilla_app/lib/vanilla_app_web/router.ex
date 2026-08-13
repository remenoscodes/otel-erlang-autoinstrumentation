defmodule VanillaAppWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VanillaAppWeb do
    pipe_through :api

    get "/items", ItemController, :index
    get "/outbound", ItemController, :outbound
    get "/jobs", ItemController, :jobs
  end
end
