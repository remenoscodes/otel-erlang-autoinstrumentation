defmodule OtelAutoBootstrap.MixProject do
  use Mix.Project

  @source_url "https://github.com/remenoscodes/otel-erlang-autoinstrumentation"
  @version "0.1.0"

  # This package plays the role of the "auto-instrumentation distribution"
  # that an OpenTelemetry Operator initContainer would copy into a shared
  # volume. Its compiled output (_build/prod/lib) is the payload: the OTel
  # SDK, the OTLP exporter, the contrib instrumentations, and one extra OTP
  # application (:otel_auto_bootstrap) that knows how to activate everything
  # inside a foreign, already-booted OTP release. See README.md for the
  # zero-code injection mechanism and PROPOSAL.md for the design rationale.
  def project do
    [
      app: :otel_auto_bootstrap,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "otel_auto_bootstrap",
      source_url: @source_url,
      docs: docs(),
      erlc_options: erlc_options(),
      dialyzer: dialyzer()
    ]
  end

  defp dialyzer do
    [
      # :ecto, :phoenix, and :bandit are deliberately NOT deps of this
      # package (they're detected via Code.ensure_loaded?/1 at runtime,
      # provided by whatever host release this gets injected into) — so
      # they're not addable to the PLT, and Dialyzer's closed-world
      # analysis can't see past the ensure_loaded?/1 guards around calls
      # into them. That produces exactly one expected unknown_function
      # warning (Ecto.Repo.all_running/0), silenced in .dialyzer_ignore.exs
      # with the same explanation. Everything else in plt_add_apps here IS
      # a real dependency of this package.
      plt_add_apps: [:mix, :ranch, :cowboy, :cowboy_telemetry],
      flags: [:error_handling, :underspecs],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # -DTEST gates otel_auto_bootstrap_shim.erl's test-only exports (see its
  # -ifdef(TEST) block) — those helpers stay unexported in every build
  # except MIX_ENV=test, so a real distribution build never carries them.
  defp erlc_options do
    if Mix.env() == :test, do: [{:d, :TEST}], else: []
  end

  def application do
    # No mod/supervisor: the bootstrapper is invoked explicitly via -eval,
    # by otel_auto_bootstrap_shim (plain Erlang) — never started as a
    # normal OTP application dependency of anything. See the moduledocs
    # on OtelAutoBootstrap and otel_auto_bootstrap_shim for why the split
    # between the two exists and why it's load-bearing.
    [extra_applications: []]
  end

  defp deps do
    [
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_cowboy, "~> 1.0"},
      {:opentelemetry_req, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Zero-code OpenTelemetry auto-instrumentation for BEAM (Erlang/Elixir) " <>
      "releases. Loads the OTel SDK and contrib instrumentations into a " <>
      "foreign, already-booted release via -eval — no source or build " <>
      "changes to the target application."
  end

  defp package do
    [
      name: "otel_auto_bootstrap",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Design proposal" => "#{@source_url}/blob/main/PROPOSAL.md"
      },
      files: ~w(lib src mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "PROPOSAL.md", "CHANGELOG.md", "LICENSE"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
