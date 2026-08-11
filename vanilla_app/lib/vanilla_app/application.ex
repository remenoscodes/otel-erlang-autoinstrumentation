defmodule VanillaApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VanillaApp.Repo,
      {Phoenix.PubSub, name: VanillaApp.PubSub},
      VanillaAppWeb.Endpoint
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: VanillaApp.Supervisor)
    seed_database()
    result
  end

  # Tiny embedded schema setup so the /items endpoint exercises Ecto
  # without needing migrations or an external database server.
  defp seed_database do
    VanillaApp.Repo.query!("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)")

    case VanillaApp.Repo.query!("SELECT COUNT(*) FROM items") do
      %{rows: [[0]]} ->
        VanillaApp.Repo.query!("INSERT INTO items (name) VALUES ('alpha'), ('beta'), ('gamma')")

      _ ->
        :ok
    end
  end
end
