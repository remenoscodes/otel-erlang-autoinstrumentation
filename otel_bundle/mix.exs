defmodule OtelAutoBootstrap.MixProject do
  use Mix.Project

  # This project plays the role of the "auto-instrumentation distribution"
  # that an OpenTelemetry Operator initContainer would copy into a shared
  # volume. Its compiled output (_build/prod/lib) is the payload: the OTel
  # SDK, the OTLP exporter, the contrib instrumentations, and one extra OTP
  # application (:otel_auto_bootstrap) that knows how to activate everything
  # inside a foreign, already-booted OTP release.
  def project do
    [
      app: :otel_auto_bootstrap,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    # No mod/supervisor: the bootstrapper is invoked explicitly via -eval.
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
      {:opentelemetry_cowboy, "~> 1.0"}
    ]
  end
end
