defmodule VanillaApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Repo and PubSub start first, alone, so seed_database/0 can create the
    # oban_jobs table before Oban.Stager's first tick queries it — Oban has
    # no migration runner here (see seed_database/0), so the table has to
    # exist before the Oban child is started, not just before any HTTP
    # request arrives (unlike the plain `items` table, which /items only
    # touches lazily).
    base_children = [
      VanillaApp.Repo,
      {Phoenix.PubSub, name: VanillaApp.PubSub}
    ]

    {:ok, sup} = Supervisor.start_link(base_children, strategy: :one_for_one, name: VanillaApp.Supervisor)
    seed_database()

    for spec <- [{Oban, oban_config()}, VanillaAppWeb.Endpoint] do
      {:ok, _pid} = Supervisor.start_child(sup, spec)
    end

    {:ok, sup}
  end

  defp oban_config do
    [engine: Oban.Engines.Lite, repo: VanillaApp.Repo, queues: [default: 5]]
  end

  # Tiny embedded schema setup so the /items and /jobs endpoints exercise
  # Ecto and Oban without needing migrations or an external database server.
  defp seed_database do
    VanillaApp.Repo.query!("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)")

    case VanillaApp.Repo.query!("SELECT COUNT(*) FROM items") do
      %{rows: [[0]]} ->
        VanillaApp.Repo.query!("INSERT INTO items (name) VALUES ('alpha'), ('beta'), ('gamma')")

      _ ->
        :ok
    end

    # Mirrors Oban.Migrations.SQLite.up/1 (see deps/oban/lib/oban/migrations/sqlite.ex)
    # as raw SQL, since this app has no Ecto migration runner.
    VanillaApp.Repo.query!("""
    CREATE TABLE IF NOT EXISTS oban_jobs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      state TEXT NOT NULL DEFAULT 'available',
      queue TEXT NOT NULL DEFAULT 'default',
      worker TEXT NOT NULL,
      args TEXT NOT NULL DEFAULT '{}',
      meta TEXT NOT NULL DEFAULT '{}',
      tags TEXT NOT NULL DEFAULT '[]',
      errors TEXT NOT NULL DEFAULT '[]',
      attempt INTEGER NOT NULL DEFAULT 0,
      max_attempts INTEGER NOT NULL DEFAULT 20,
      priority INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      scheduled_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      attempted_at TEXT,
      attempted_by TEXT NOT NULL DEFAULT '[]',
      cancelled_at TEXT,
      completed_at TEXT,
      discarded_at TEXT
    )
    """)

    VanillaApp.Repo.query!("""
    CREATE INDEX IF NOT EXISTS oban_jobs_state_queue_priority_scheduled_at_id_index
    ON oban_jobs (state, queue, priority, scheduled_at, id)
    """)
  end
end
