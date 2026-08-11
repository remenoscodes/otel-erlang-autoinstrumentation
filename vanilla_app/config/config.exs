import Config

config :vanilla_app, VanillaAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: VanillaAppWeb.ErrorJSON], layout: false],
  pubsub_server: VanillaApp.PubSub,
  server: true

config :phoenix, :json_library, Jason

config :logger, level: :info
