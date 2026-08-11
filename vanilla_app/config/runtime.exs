import Config

config :vanilla_app, VanillaApp.Repo,
  database: System.get_env("DB_PATH", "/tmp/vanilla_app.db"),
  # SQLite has a single writer; a bigger pool just means more connections
  # racing for the same lock. pool_size: 1 avoids the "database is locked"
  # boot failures a concurrent request burst would otherwise trigger.
  pool_size: 1

config :vanilla_app, VanillaAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: String.duplicate("spike-not-a-secret-", 4)
