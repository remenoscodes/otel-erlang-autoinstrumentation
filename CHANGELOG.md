# Changelog

All notable changes to `otel_auto_bootstrap` are documented here.

## [0.1.0] - unreleased

Initial version. Not yet published to Hex — see README.md's "Installation"
section. Validated by six end-to-end spikes (`run_spike.sh`,
`run_spike_erlang.sh`) and a unit test suite (`mix test`); see README.md and
PROPOSAL.md for the full narrative.

### Added

- `otel_auto_bootstrap_shim` (Erlang): phase 0/1 of the bootstrap — code
  path setup and explicit, multi-pass module loading of the bundle's full
  OTP dependency closure, including `elixir`/`logger` themselves on hosts
  that have no Elixir at all. Guards against double invocation (e.g.
  `reboot_system_after_config: true`). Suppresses expected `-on_load`
  retry noise from the code server during loading.
- `OtelAutoBootstrap` (Elixir): phase 2/3 — starts the OTel SDK + OTLP
  exporter, then detects and activates whichever of Phoenix, Bandit, plain
  Cowboy, Ecto repos, the Req HTTP client, and Oban are actually
  present/used in the host release.
- Req client instrumentation via `Req.default_options(plugins: [OpentelemetryReq | ...])`
  — Req's own global plugin hook, since (unlike Phoenix/Bandit/Ecto/Cowboy)
  it has no `:telemetry`-shaped switch to detect-and-flip. Guarded by
  `OtelAutoBootstrap.host_provided?/1`, which distinguishes "the host's own
  release boot loaded this app" from "this bundle's own dependency closure
  happened to load it" — needed specifically because `opentelemetry_req`,
  unlike the other contrib packages here, declares `req` as a normal
  (not dev/test-only) dependency, so this bundle always carries its own
  copy regardless of host usage.
- Oban job instrumentation via `OpentelemetryOban.setup/0` — a plain global
  `:telemetry.attach_many` call, so it fits the same detect-and-activate
  pattern as Phoenix/Bandit/Ecto, but still needs
  `host_provided?(:oban)` for the same reason Req does:
  `opentelemetry_oban` also declares its target library (`oban`) as a
  normal dependency.
- Plain-Cowboy retrofit: `cowboy_telemetry_h` is installed onto
  already-running Ranch listeners via `ranch:set_protocol_options/2`, with
  zero configuration required from the target application.
- Ecto repo telemetry-prefix auto-discovery via `Ecto.Repo.all_running/0` —
  no user configuration needed. Also guarded by `host_provided?(:ecto)`,
  added after adding Oban: `oban`'s own dependency on `ecto_sql` made
  `:ecto` part of this bundle's transitive closure on every host, which
  broke the plain `Code.ensure_loaded?(Ecto.Repo)` detection signal this
  had relied on since the first spike (see README.md's "Phase 3b" for the
  full story, including the crash on the pure-Erlang fixture that caught
  it).
- Integration test fixtures (`vanilla_app/`, a Phoenix + Ecto + Req + Oban
  `mix release`; `vanilla_app_erlang/`, a pure-Erlang Cowboy release with
  no Elixir/Mix anywhere) and the two scripts that boot them with this
  package injected entirely from outside, exactly as an
  OpenTelemetry Operator `inject-erlang` mechanism would.
- CI (`.github/workflows/spikes.yml`) running both integration spikes, the
  unit test suite, and Dialyzer on every push, matrixed across OTP
  25/Elixir 1.17 and OTP 28/Elixir 1.20.
- Dialyzer (`mix dialyzer`), clean with no warnings to ignore — `:ecto`
  became a real, PLT-visible transitive dependency once Oban was added
  (see `mix.exs`'s `dialyzer/0` for the history of what used to need
  `.dialyzer_ignore.exs` and why it no longer does).
- `SECURITY.md` documenting the one currently-known advisory (in `cowlib`,
  a transitive dependency — not in this package's own code) and why it
  isn't actionable yet.
- `.formatter.exs`, and `mix hex.build` verified to produce a valid,
  publishable package tarball (not yet published — see "Installation").

### Known limitations

See README.md's "Known gaps" section — in particular, the startup race
(a request served before `-eval` attaches instrumentation is never traced)
is structural, not a bug scheduled to be fixed.
