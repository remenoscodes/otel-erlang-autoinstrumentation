defmodule OtelAutoBootstrapTest do
  use ExUnit.Case, async: true

  # OtelAutoBootstrap.run/0 itself has heavy side effects (starts the SDK,
  # attaches :telemetry handlers, mutates ranch listener state) that only
  # make sense against a real booted release — that end-to-end behavior is
  # what run_spike.sh / run_spike_erlang.sh actually verify. These tests
  # cover the two pieces of genuinely pure decision logic the module
  # exposes (@doc false, but public — see each function's own doc) for
  # exactly this purpose.

  # ecto_telemetry_prefix/2 only ever calls Module.split/1 on its `repo`
  # argument, which works on any module-shaped atom without requiring the
  # module to actually be defined/compiled — MyApp.Repo below is never
  # declared as a real module.

  describe "ecto_telemetry_prefix/2" do
    test "derives the prefix from the repo module's own name when config sets nothing" do
      assert OtelAutoBootstrap.ecto_telemetry_prefix(MyApp.Repo, []) == [:my_app, :repo]
    end

    test "an explicit :telemetry_prefix in the repo's config always wins" do
      config = [telemetry_prefix: [:custom, :prefix]]
      assert OtelAutoBootstrap.ecto_telemetry_prefix(MyApp.Repo, config) == [:custom, :prefix]
    end

    test "works for single-segment repo module names too" do
      assert OtelAutoBootstrap.ecto_telemetry_prefix(Repo, []) == [:repo]
    end
  end

  describe "updated_protocol_options/1" do
    test "no stream_handlers key at all: adds the default plus the retrofit, in front" do
      assert OtelAutoBootstrap.updated_protocol_options(%{}) ==
               {:changed, %{stream_handlers: [:cowboy_telemetry_h, :cowboy_stream_h]},
                "default stream_handlers"}
    end

    test "preserves other protocol option keys when applying the default" do
      opts = %{env: %{dispatch: :some_dispatch}}

      assert {:changed, updated, "default stream_handlers"} =
               OtelAutoBootstrap.updated_protocol_options(opts)

      assert updated.env == %{dispatch: :some_dispatch}
      assert updated.stream_handlers == [:cowboy_telemetry_h, :cowboy_stream_h]
    end

    test "existing stream_handlers without cowboy_telemetry_h: prepends it" do
      opts = %{stream_handlers: [:cowboy_stream_h]}

      assert OtelAutoBootstrap.updated_protocol_options(opts) ==
               {:changed, %{stream_handlers: [:cowboy_telemetry_h, :cowboy_stream_h]},
                "existing stream_handlers"}
    end

    test "cowboy_telemetry_h already present: unchanged (idempotent — safe on a second retrofit attempt)" do
      opts = %{stream_handlers: [:cowboy_telemetry_h, :cowboy_stream_h]}
      assert OtelAutoBootstrap.updated_protocol_options(opts) == :unchanged
    end

    test "cowboy_telemetry_h present anywhere in an unusual custom order: still unchanged" do
      opts = %{stream_handlers: [:some_other_handler, :cowboy_telemetry_h, :cowboy_stream_h]}
      assert OtelAutoBootstrap.updated_protocol_options(opts) == :unchanged
    end
  end

  describe "host_provided?/1" do
    # Mirrors what otel_auto_bootstrap_shim's record_host_loaded_apps/0
    # actually writes — same key, same shape (a plain list of app atoms).
    setup do
      on_exit(fn -> :persistent_term.erase({:otel_auto_bootstrap_shim, :host_loaded_apps}) end)
    end

    test "true when the app is in the recorded host-loaded snapshot" do
      :persistent_term.put({:otel_auto_bootstrap_shim, :host_loaded_apps}, [:req, :kernel])
      assert OtelAutoBootstrap.host_provided?(:req)
    end

    test "false when the app is absent from the snapshot" do
      :persistent_term.put({:otel_auto_bootstrap_shim, :host_loaded_apps}, [:kernel])
      refute OtelAutoBootstrap.host_provided?(:req)
    end

    test "false (not a crash) when the shim never ran and no snapshot exists at all" do
      refute OtelAutoBootstrap.host_provided?(:req)
    end
  end

  describe "updated_default_options/1" do
    test "no existing options at all: adds OpentelemetryReq as the sole plugin" do
      assert OtelAutoBootstrap.updated_default_options([]) ==
               {:changed, [plugins: [OpentelemetryReq]]}
    end

    test "preserves every other existing default option (base_url, headers, ...)" do
      current = [base_url: "https://example.com", headers: [{"x-app", "demo"}]]

      assert {:changed, updated} = OtelAutoBootstrap.updated_default_options(current)
      assert updated[:base_url] == "https://example.com"
      assert updated[:headers] == [{"x-app", "demo"}]
      assert updated[:plugins] == [OpentelemetryReq]
    end

    test "existing plugins the host already configured: OpentelemetryReq is prepended, not replacing them" do
      current = [plugins: [SomeHostPlugin]]

      assert OtelAutoBootstrap.updated_default_options(current) ==
               {:changed, [plugins: [OpentelemetryReq, SomeHostPlugin]]}
    end

    test "OpentelemetryReq already present (e.g. a second bootstrap run): unchanged, not duplicated" do
      current = [plugins: [OpentelemetryReq]]
      assert OtelAutoBootstrap.updated_default_options(current) == :unchanged
    end

    test "OpentelemetryReq present alongside other plugins: still unchanged" do
      current = [plugins: [SomeHostPlugin, OpentelemetryReq]]
      assert OtelAutoBootstrap.updated_default_options(current) == :unchanged
    end
  end
end
