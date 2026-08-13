defmodule VanillaApp.MixProject do
  use Mix.Project

  # DELIBERATELY NO OpenTelemetry dependencies of any kind.
  # This app represents a production Phoenix app whose owners never
  # added observability. The spike proves it can be instrumented
  # entirely from outside the release.
  def project do
    [
      app: :vanilla_app,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        vanilla_app: [include_executables_for: [:unix]]
      ]
    ]
  end

  def application do
    [
      mod: {VanillaApp.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.17"},
      # Req IS a real dependency here — unlike opentelemetry deps, which
      # this app has none of. The point of the /outbound route is to prove
      # a genuinely vanilla app that already uses Req gets its outbound
      # calls traced with zero code of its own — this app never imports or
      # calls OpentelemetryReq anywhere.
      {:req, "~> 0.5"}
    ]
  end
end
