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
    setup_req()
    setup_oban()
  end

  @doc false
  # Was `app` already a loaded OTP application before this bundle's own
  # phase 0/1 (otel_auto_bootstrap_shim's dependency-closure walk) ran —
  # i.e. did the HOST's own release boot load it, as opposed to this
  # bundle transitively supplying it?
  #
  # Needed specifically because not every contrib package — nor every
  # TRANSITIVE dependency of one — follows the "declare the instrumented
  # library as a dev/test-only dependency" convention:
  # opentelemetry_phoenix/opentelemetry_bandit do (so this bundle never
  # carries its own phoenix/bandit, and Code.ensure_loaded?/1 alone is a
  # reliable "does the host use this" signal for them), but
  # opentelemetry_req and opentelemetry_oban declare `req`/`oban` as
  # normal, unconditional dependencies of their own — and oban itself pulls
  # in `ecto_sql`/`ecto` the same way, one level further down, which is
  # what makes setup_ecto_repos/0 need this guard too even though
  # opentelemetry_ecto itself declares ecto correctly. Any of these means
  # this bundle DOES carry its own copy, and a plain Code.ensure_loaded?/1
  # check would be true on every host regardless of whether it actually
  # uses the library. See otel_auto_bootstrap_shim.erl's
  # `record_host_loaded_apps/0` for where this gets captured, and
  # setup_ecto_repos/0, setup_req/0, and setup_oban/0 below for the three
  # places today that need it.
  def host_provided?(app) do
    app in :persistent_term.get({:otel_auto_bootstrap_shim, :host_loaded_apps}, [])
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
          {:changed, %{opts | stream_handlers: [:cowboy_telemetry_h | handlers]},
           "existing stream_handlers"}
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
  #
  # host_provided?(:ecto) is required here for the same reason setup_req/0
  # and setup_oban/0 need it, but discovered a level deeper: opentelemetry_
  # ecto itself correctly declares ecto_sql as dev/test-only, so it alone
  # never puts :ecto in this bundle — but oban (a REAL dependency of
  # opentelemetry_oban) declares ecto_sql as a normal, unconditional
  # dependency of its own. The moment opentelemetry_oban was added, :ecto
  # became part of this bundle transitively through oban, and
  # Code.ensure_loaded?(Ecto.Repo) alone stopped meaning "the host uses
  # Ecto" — it became true on every host, Ecto or not. Caught by
  # run_spike_erlang.sh: Ecto.Repo.all_running/0 calls :ets.match/2 against
  # a registry table that only exists once some Ecto.Repo has actually
  # started, so on a host with no Ecto at all this raised :badarg instead
  # of just finding zero repos.
  defp setup_ecto_repos do
    if Code.ensure_loaded?(Ecto.Repo) and function_exported?(Ecto.Repo, :all_running, 0) and
         host_provided?(:ecto) do
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

  # Req has no global "instrument every request" switch the way :telemetry-
  # based libraries do — OpentelemetryReq.attach/2 opts in one specific
  # %Req.Request{} at a time, meaning the naive "detect + call setup()"
  # pattern used everywhere else in this module has nothing global to hook.
  #
  # Req does have a real global extension point for exactly this purpose,
  # though: Req.new/1 pops a `:plugins` option out of whatever
  # Req.default_options/0 currently returns and runs each one as
  # `plugin.attach(request)` (see deps/req/lib/req.ex's `run_plugins/2`) —
  # and OpentelemetryReq itself exports `attach/1` with that exact shape.
  # So `Req.default_options(plugins: [OpentelemetryReq | existing])`
  # retroactively instruments every `Req.new/1` call made from this point
  # forward, process-wide, with zero code in the host application. This
  # has the same startup-race shape as everything else here: a Req client
  # already built via Req.new/1 before this runs keeps whatever plugins it
  # already had.
  #
  # host_provided?/1 above is what keeps this from firing on a host that
  # never uses Req at all — see its own doc for why that check exists.
  defp setup_req do
    if Code.ensure_loaded?(Req) and Code.ensure_loaded?(OpentelemetryReq) and
         host_provided?(:req) do
      safe_setup("req", fn ->
        case updated_default_options(Req.default_options()) do
          {:changed, updated} -> Req.default_options(updated)
          :unchanged -> :ok
        end

        :ok
      end)
    end
  end

  @doc false
  # Pure decision logic for setup_req/0, split out so it's unit-testable
  # without Req itself loaded. Preserves every existing default option
  # (base_url, headers, any plugins the host already configured, ...) and
  # only adds OpentelemetryReq to :plugins if it isn't already there —
  # idempotent, so a second bootstrap run (reboot_system_after_config)
  # never double-registers it.
  def updated_default_options(current) do
    plugins = Keyword.get(current, :plugins, [])

    if OpentelemetryReq in plugins do
      :unchanged
    else
      {:changed, Keyword.put(current, :plugins, [OpentelemetryReq | plugins])}
    end
  end

  # Unlike Req, Oban's OpentelemetryOban.setup/1 IS a plain global
  # :telemetry.attach_many call (subscribing to [:oban, :job, ...] and
  # [:oban, :plugin, ...], which Oban emits regardless of how many named
  # instances are running in the VM) — the same "detect + call setup()"
  # shape as Bandit/Phoenix. The only reason this isn't as simple as those
  # is the same one Req needed: opentelemetry_oban declares `oban` as a
  # normal dependency, so host_provided?/1 is required here too (see its
  # doc). No repo-style enumeration needed, unlike setup_ecto_repos/0 —
  # Oban's telemetry events aren't namespaced per instance name.
  defp setup_oban do
    if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(OpentelemetryOban) and
         host_provided?(:oban) do
      safe_setup("oban", fn -> OpentelemetryOban.setup() end)
    end
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
