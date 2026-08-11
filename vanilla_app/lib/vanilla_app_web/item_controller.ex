defmodule VanillaAppWeb.ItemController do
  use Phoenix.Controller, formats: [:json]

  alias VanillaApp.{Item, Repo}

  def index(conn, _params) do
    items = Repo.all(Item)
    json(conn, %{count: length(items), items: Enum.map(items, & &1.name)})
  end
end
