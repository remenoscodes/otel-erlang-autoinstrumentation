defmodule OtelAutoBootstrap do
  @moduledoc """
  SDK-start and instrumentation-activation half of the zero-code OTel
  bootstrapper. `otel_auto_bootstrap_shim` (plain Erlang) is the actual
  `-eval` entry point and owns phases 0/1 — code path setup and explicit
  module loading of the bundle's full OTP dependency closure, including
  this very module's app (`otel_auto_bootstrap`) and, on hosts with no
  Elixir at all, `elixir`/`logger` themselves.

  That split is load-bearing, not stylistic: this module is Elixir
  bytecode, and calling any of its functions — even a log line, since
  Elixir string interpolation desugars to Kernel/String.Chars calls —
  requires Elixir's own runtime to already be loaded and callable. On a
  mix release host that's automatic (the release IS an Elixir app), but
  proving this bundle can also instrument a host with no Elixir at all
  (`run_spike_erlang.sh`) surfaced the circular dependency directly: this
  module's own code cannot be the thing that loads Elixir's runtime,
  because it needs that runtime just to run. See
  `otel_auto_bootstrap_shim`'s moduledoc for the full explanation and the
  crash (`{undef, ['Elixir.Kernel', inspect, ...]}`) that proved it.

  `run/0` is called by the shim only after that loading is complete, so
  by the time any function here executes, calling into Kernel/Enum/String
  is safe. Responsibilities from here:

    * start the OTel SDK + OTLP exporter (config comes from standard
      OTEL_* environment variables, which the Erlang SDK reads natively)
    * detect which instrumentable libraries the release actually uses
      (Phoenix? Bandit? Cowboy? Ecto repos?) and activate only those
    * never crash the host application: any failure degrades to a log line

  ## Known, structural limitation: the startup race

  `-eval`/`-run`/`-s` are all processed by `init` after the boot script has
  already applied `{apply, {application, start_boot, [App, permanent]}}` for
  every release application — verified experimentally by comparing log
  timestamps: the Phoenix endpoint's "Running ... at ..." line is always
  emitted before the shim's first log line, for both `-eval` and `-run`.
  That means the HTTP listener is already accepting connections before any
  instrumentation is attached, for every command-line hook `erl` offers.
  There is no zero-code way to close this window from outside the release —
  doing so would require intercepting the boot script itself (e.g. a custom
  `.boot` file), which is a rebuild, not an injection. The window is small
  (sub-second; see `run_spike.sh`'s race-window diagnostic) and, since real
  deployments gate Kubernetes readiness on the application actually being
  up, is very unlikely to be user-visible in production — but it is a real,
  permanent gap, not a bug to eventually fix in this module. The plain-
  Cowboy retrofit path (`retrofit_cowboy_telemetry/0`, below) has the same
  shape at a second layer: a connection already open when the retrofit
  runs keeps its original, uninstrumented options.
  """

  def run do
    ensure_telemetry_started()
    start_sdk()
    activate_instrumentations()

    log("done")
  end

  # Every instrumentation here (Phoenix, Bandit, Ecto, the cowboy_telemetry
  # retrofit) works by calling :telemetry.attach/attach_many, which needs
  # :telemetry's own gen_server (telemetry_handler_table) running — not
  # just its module loaded. On a mix release host this is free: Phoenix/
  # Bandit/Ecto already depend on and start :telemetry as part of their own
  # supervision tree. On the pure-Erlang host (run_spike_erlang.sh) nothing
  # else starts it, and every instrumentation setup call failed with
  # {:noproc, {:gen_server, :call, [:telemetry_handler_table, ...]}} until
  # this was added — loaded-but-not-started is a different failure mode
  # than not-loaded-at-all, and the shim's job (phase 0/1) only ever
  # covered the latter.
  defp ensure_telemetry_started do
    {:ok, _} = Application.ensure_all_started(:telemetry)
  end

  # -- phase 2: SDK + exporter ------------------------------------------------

  defp start_sdk do
    # The Erlang SDK natively honors OTEL_TRACES_EXPORTER,
    # OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES
    # — exactly the variables the Operator's existing `inject-sdk` sets.
    {:ok, started} = Application.ensure_all_started(:opentelemetry_exporter)
    {:ok, started2} = Application.ensure_all_started(:opentelemetry)
    log("SDK started (apps: #{inspect(started ++ started2)})")
  end

  # -- phase 3: detection + activation ---------------------------------------

  defp activate_instrumentations do
    if Code.ensure_loaded?(Bandit), do: setup_bandit()
    if Code.ensure_loaded?(:cowboy), do: setup_cowboy()
    if Code.ensure_loaded?(Phoenix), do: setup_phoenix()
    setup_ecto_repos()
  end

  defp setup_bandit do
    safe_setup("bandit", fn -> OpentelemetryBandit.setup() end)
  end

  defp setup_cowboy do
    if Code.ensure_loaded?(Phoenix) do
      # Phoenix on the cowboy2 adapter is already fully covered by
      # setup_phoenix/0's OpentelemetryPhoenix.setup/1 call. Also
      # retrofitting cowboy_telemetry underneath it would double-instrument
      # every request at two layers (a phoenix.* span and a duplicate
      # HTTP-method-named span from cowboy_telemetry, both wrapping the
      # same request) — so the retrofit path only runs for plain Cowboy.
      :ok
    else
      safe_setup("cowboy (retrofit cowboy_telemetry)", fn -> retrofit_cowboy_telemetry() end)

      safe_setup("cowboy", fn ->
        if Code.ensure_loaded?(:opentelemetry_cowboy) do
          :opentelemetry_cowboy.setup()
        else
          log("cowboy detected but opentelemetry_cowboy not in bundle; skipping")
        end
      end)
    end
  end

  # Unlike Phoenix/Bandit, plain Cowboy emits no :telemetry events of its
  # own — cowboy_telemetry is a *stream handler* that has to be present in
  # a listener's `stream_handlers` option for `[cowboy, request, ...]`
  # events to fire at all. A genuinely vanilla Cowboy app has no reason to
  # have ever added it.
  #
  # This retrofits it onto every already-running ranch listener, entirely
  # from outside: ranch stores each listener's protocol options in
  # `ranch_server` and hands a fresh copy to `ranch_conns_sup` for every
  # ACCEPTED CONNECTION (verified by reading ranch_conns_sup.erl — it calls
  # ranch_server:get_protocol_options/1 per accept, not once at listener
  # start), so `ranch:set_protocol_options/2` changes what NEW connections
  # get without touching the running listener process. Verified end-to-end
  # against a real listener: `[cowboy, request, start/stop]` events fire
  # for a request made after the retrofit, using a listener that was
  # started with no `stream_handlers` option at all.
  #
  # This has the same shape as the -eval startup race: connections already
  # open when this runs keep their original (uninstrumented) options; only
  # connections opened after this point are traced.
  defp retrofit_cowboy_telemetry do
    if Code.ensure_loaded?(:ranch) and Code.ensure_loaded?(:cowboy_telemetry_h) do
      for {ref, _info} <- :ranch.info() do
        opts = :ranch.get_protocol_options(ref)

        case updated_protocol_options(opts) do
          {:changed, updated, reason} ->
            :ranch.set_protocol_options(ref, updated)
            log("retrofitted cowboy_telemetry_h onto ranch listener #{inspect(ref)} (#{reason})")

          :unchanged ->
            :ok
        end
      end
    else
      log("cowboy_telemetry not in bundle; cannot retrofit plain-Cowboy listeners")
    end
  end

  @doc false
  # Pure decision logic for retrofit_cowboy_telemetry/0, split out so it's
  # unit-testable without a running ranch listener. Given a listener's
  # current protocol options:
  #   - no `stream_handlers` key at all: Cowboy is about to apply its own
  #     default ([cowboy_stream_h]) internally — reproduce that default
  #     explicitly so ours can sit in front of it.
  #   - `stream_handlers` present, `cowboy_telemetry_h` not yet in it:
  #     prepend it.
  #   - already present (e.g. a second retrofit attempt, or an app that
  #     already had it): no-op, idempotent.
  #   - anything else shaped unexpectedly: no-op, never crash on it.
  def updated_protocol_options(opts) do
    case opts do
      %{stream_handlers: handlers} ->
        if :cowboy_telemetry_h in handlers do
          :unchanged
        else
          {:changed, %{opts | stream_handlers: [:cowboy_telemetry_h | handlers]}, "existing stream_handlers"}
        end

      %{} = opts ->
        updated = Map.put(opts, :stream_handlers, [:cowboy_telemetry_h, :cowboy_stream_h])
        {:changed, updated, "default stream_handlers"}

      _ ->
        :unchanged
    end
  end

  defp setup_phoenix do
    adapter = if Code.ensure_loaded?(Bandit), do: :bandit, else: :cowboy2
    safe_setup("phoenix", fn -> OpentelemetryPhoenix.setup(adapter: adapter) end)
  end

  # Ecto repos register themselves at runtime, so `Ecto.Repo.all_running/0`
  # gives us every started repo — and each repo's config carries its
  # telemetry_prefix. This answers the "how does a zero-code agent discover
  # the repo's telemetry prefix?" question without any user configuration.
  defp setup_ecto_repos do
    if Code.ensure_loaded?(Ecto.Repo) and function_exported?(Ecto.Repo, :all_running, 0) do
      for repo <- Ecto.Repo.all_running() do
        prefix = ecto_telemetry_prefix(repo, repo.config())

        safe_setup("ecto #{inspect(repo)} prefix=#{inspect(prefix)}", fn ->
          OpentelemetryEcto.setup(prefix)
        end)
      end
    end
  end

  @doc false
  # Pure derivation logic for setup_ecto_repos/0, split out so it's
  # unit-testable without a running repo. `telemetry_prefix` is standard
  # Ecto repo config (defaults to the repo module's own name, snake_cased,
  # when the app never set it explicitly) — reading it directly answers
  # "how does a zero-code agent discover the repo's telemetry prefix?"
  # without requiring any user configuration.
  def ecto_telemetry_prefix(repo, config) do
    config[:telemetry_prefix] ||
      repo |> Module.split() |> Enum.map(&(&1 |> Macro.underscore() |> String.to_atom()))
  end

  defp safe_setup(label, fun) do
    case fun.() do
      :ok -> log("instrumentation active: #{label}")
      other -> log("instrumentation #{label} returned: #{inspect(other)}")
    end
  catch
    kind, reason -> log("instrumentation #{label} failed: #{inspect(kind)} #{inspect(reason)}")
  end

  defp log(msg), do: IO.puts("[otel_auto_bootstrap] #{msg}")
end
