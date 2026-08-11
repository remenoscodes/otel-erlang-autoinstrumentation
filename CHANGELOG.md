# Changelog

All notable changes to `otel_auto_bootstrap` are documented here.

## [0.1.0] - unreleased

Initial version. Not yet published to Hex — see README.md's "Installation"
section. Validated by four end-to-end spikes (`run_spike.sh`,
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
  Cowboy, and Ecto repos are actually present in the host release.
- Plain-Cowboy retrofit: `cowboy_telemetry_h` is installed onto
  already-running Ranch listeners via `ranch:set_protocol_options/2`, with
  zero configuration required from the target application.
- Ecto repo telemetry-prefix auto-discovery via `Ecto.Repo.all_running/0` —
  no user configuration needed.
- Integration test fixtures (`vanilla_app/`, a Phoenix + Ecto `mix
  release`; `vanilla_app_erlang/`, a pure-Erlang Cowboy release with no
  Elixir/Mix anywhere) and the two scripts that boot them with this
  package injected entirely from outside, exactly as an
  OpenTelemetry Operator `inject-erlang` mechanism would.
- CI (`.github/workflows/spikes.yml`) running both integration spikes, the
  unit test suite, and Dialyzer on every push, matrixed across OTP
  25/Elixir 1.17 and OTP 28/Elixir 1.20.
- Dialyzer (`mix dialyzer`), with `.dialyzer_ignore.exs` documenting the
  one expected warning (a call into `Ecto.Repo`, deliberately not a
  dependency of this package — see the ignore file and `mix.exs`'s
  `dialyzer/0` for why).
- `SECURITY.md` documenting the one currently-known advisory (in `cowlib`,
  a transitive dependency — not in this package's own code) and why it
  isn't actionable yet.
- `.formatter.exs`, and `mix hex.build` verified to produce a valid,
  publishable package tarball (not yet published — see "Installation").

### Known limitations

See README.md's "Known gaps" section — in particular, the startup race
(a request served before `-eval` attaches instrumentation is never traced)
is structural, not a bug scheduled to be fixed.
