# Proposal: zero-code OpenTelemetry auto-instrumentation for BEAM releases

Status: draft, backed by five passing spikes in this repository,
including a two-OTP-major compatibility check and a working Hex package
(`otel_auto_bootstrap`, not yet published). Written to be posted as a
GitHub Discussion / RFC to
the OpenTelemetry Erlang/Elixir SIG
(`open-telemetry/opentelemetry-erlang-contrib`) ahead of any
`opentelemetry-operator` PR.

## Summary

The [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
auto-instruments Java, Node.js, Python, .NET, Go, Apache HTTPD, and Nginx
workloads with zero code changes: an initContainer copies a language-specific
instrumentation payload into a shared volume, and a mutating webhook adds
environment variables that make the target process pick it up at startup.
PHP support is in flight ([operator PR
#5220](https://github.com/open-telemetry/opentelemetry-operator/pull/5220)).
Erlang/Elixir is not in this matrix, despite `opentelemetry-erlang` shipping
a stable, hex.pm-distributed SDK, OTLP exporter, and a healthy set of contrib
instrumentations (Phoenix, Ecto, Bandit, Cowboy, ...).

This proposal is for the missing piece: a BEAM-specific auto-instrumentation
distribution and bootstrapper that plugs into the Operator's existing
architecture as `instrumentation.opentelemetry.io/inject-erlang`. It is
**not** a proposal to build new instrumentation — every span in the spikes
below comes from existing, unmodified `opentelemetry-erlang-contrib`
packages. The work is entirely in the bootstrap layer: getting those
packages loaded and activated inside a release that was never built to know
about them.

Five spikes in this repo (Phoenix on `mix release`, hardening for
production edge cases, a from-scratch pure-Erlang Cowboy release with no
Elixir/Mix anywhere, a two-OTP-major compatibility check, and a Req HTTP
client coverage expansion that also produced a real scoping criterion for
what belongs in this bundle) validate that this is possible with an
environment-variables-only injection surface — the same surface the
Operator already uses for every other language.

## Motivation

Today, instrumenting a BEAM release with OpenTelemetry means adding
`opentelemetry`, `opentelemetry_exporter`, and the relevant contrib
libraries as `mix.exs`/`rebar.config` dependencies, wiring up each
integration's `setup/0` or `setup/1` call, and rebuilding the release. That
is a reasonable ask of a team that owns the code — it is not zero-code, and
it means every workload the Operator can already auto-instrument in every
other language it supports needs a bespoke path for BEAM.

For platform/SRE teams running many services they don't necessarily own the
source of (or don't want a redeploy-per-service rollout to add tracing),
"annotate the pod, get traces" is the actual ask, and it's the ask the
Operator already satisfies for six other languages.

## Design

```
initContainer (per-app image, built from this bundle)
    │
    ▼
shared volume: SDK + exporter + contrib instrumentations
    + otel_auto_bootstrap (this proposal's only new code)
    │
    ▼
mutating webhook sets, on the target container:
    ERL_AFLAGS = "-pa <volume>/otel_auto_bootstrap/ebin
                  -eval code:load_file(otel_auto_bootstrap_shim),
                        otel_auto_bootstrap_shim:start()"
    OTEL_AUTO_BUNDLE_LIB = <volume>
    OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT, ... (already set today
    by the Operator's existing inject-sdk mechanism)
    │
    ▼
target release boots completely unmodified
    │
    ▼
otel_auto_bootstrap_shim (plain Erlang):
    loads the bundle's full OTP dependency closure onto the code path
    │
    ▼
OtelAutoBootstrap (Elixir), once loading is guaranteed complete:
    starts the OTel SDK + OTLP exporter
    detects Phoenix / Bandit / plain Cowboy / Ecto repos
    activates only the instrumentations that apply
```

This is the same two-part shape every other language's Operator support
uses (Java's javaagent, Python's `opentelemetry-instrument` wrapper, Node's
`--require`): a payload delivered by volume mount, activated by an
environment-variable hook the target process picks up at its own startup.
BEAM's version of "the hook" is `ERL_AFLAGS`'s `-pa`/`-eval`, and BEAM's
version of "activation" is two Erlang/Elixir modules instead of one runtime
agent, for a structural reason explained below.

### Why two modules, not one

The bootstrap logic is split across a plain-Erlang shim
(`otel_auto_bootstrap_shim`) and an Elixir module (`OtelAutoBootstrap`), and
that split is load-bearing, not stylistic. `OtelAutoBootstrap` — the part
that starts the SDK and detects/activates instrumentations — is Elixir
bytecode. Calling any of its functions, even producing a log line, requires
Elixir's own runtime (`Kernel`, `String.Chars`, ...) to already be loaded
and callable. On a `mix release` host that's automatic: the release is
itself an Elixir application, so `Kernel` is resident long before `-eval`
runs. It is **not** automatic on a plain Erlang/rebar3 release with no
Elixir dependency at all — and BEAM instrumentation has to cover that case,
because a meaningful fraction of the ecosystem (Cowboy/Plug services,
`gen_statem`-based systems, anything built without Phoenix) is pure Erlang
or minimal Elixir.

The fix is that `otel_auto_bootstrap_shim` — needing nothing but
`kernel`/`stdlib`, present on every BEAM node — owns loading the bundle's
entire OTP dependency closure onto the code path first, including
`elixir`/`logger` themselves when the host doesn't already have them, and
only hands off to Elixir once that is guaranteed complete. This was found,
not designed in from the start: the first pure-Erlang-host attempt in this
repo crashed with `{undef, ['Elixir.Kernel', inspect, ...]}` before this
split existed.

## What the spikes proved

All three are in this repo and reproducible with `./run_spike.sh` /
`./run_spike_erlang.sh`. Full narrative and command-by-command evidence in
[`README.md`](./README.md); summarized here as the findings that should
inform how a real implementation gets built.

### Phase 0 — Phoenix + Ecto, `mix release` (PASS)

A Phoenix 1.7 + Bandit + Ecto (SQLite) app with **zero** OpenTelemetry
dependencies, built as a standard `mix release`, exported real Phoenix
endpoint spans and Ecto query spans over OTLP/HTTP — injected via
environment variables only, no `mix.exs`/source/build change.

Findings that shape the design:

- **`ERL_LIBS` does not work.** Production releases boot in *embedded*
  code-loading mode, which ignores `ERL_LIBS` outright (verified:
  `code:get_path/0` shows the directories were never added). `-pa` via
  `ERL_AFLAGS` is the correct, and only, primitive — this rules out the
  naive "mount a volume and set an env var" design that works for `ERTS`
  itself but not for a booted release's code path.
- **Embedded mode never loads modules on demand.** Every module of every
  bundle application has to be `code:load_file/1`'d explicitly.
  `Application.ensure_all_started/1` alone is not sufficient, and
  `-on_load` hooks that depend on sibling modules of the same app (e.g.
  `tls_certificate_check`) need a multi-pass retry, not a single sweep.
- **A pruned release is missing OTP library apps the SDK needs** (`:inets`,
  in this spike) — not just missing the OTel-specific packages. The bundle
  has to carry standard-library applications too, discovered via walking
  the full `applications` dependency closure, not just the SDK's own
  direct deps.
- **`erlexec` strips quote characters from `ERL_AFLAGS`.** An `-eval`
  expression containing a quoted Elixir module atom (`'Elixir.Foo'`)
  becomes a syntax error. The entry point has to be an Erlang-named module
  so the injected expression never needs quoting.
- **Ecto repos and their telemetry prefixes are discoverable with zero
  configuration** via `Ecto.Repo.all_running/0` and
  `repo.config()[:telemetry_prefix]` — answering what looked like it might
  need user-supplied config.
- **The release's own copies of shared deps stay authoritative for free**
  (bundle paths are appended, not prepended, to the code path; a module
  already loaded by the release is simply skipped).

### Round 2 — hardening (all gates re-verified, still PASS)

- **The startup race is structural, not a bug.** `-eval` (and `-run`,
  tested identically) are processed by `init` only *after* the boot script
  has already started every "permanent" release application — verified by
  comparing log timestamps and by forcing `-run` to crash and observing
  the endpoint was already accepting connections beforehand. There is no
  command-line boot hook that runs earlier; closing this window would mean
  intercepting the boot script itself, which is a rebuild, not an
  injection. Quantified directly in `run_spike.sh`: a burst of concurrent
  requests fired at the instant the endpoint becomes reachable, with zero
  grace period, showed **0 of 10** traced — bounded by bootstrap
  completion time (sub-second here), not unbounded.
- **`reboot_system_after_config: true` needs an idempotency guard** — such
  releases run the whole boot sequence, `ERL_AFLAGS` included, twice.
  Implemented with a `:persistent_term` flag set synchronously before the
  async bootstrap spawns; verified with a simulated double invocation.
- The `-on_load` retry noise (expected error/warning reports logged by the
  code server on the first failed pass) is cosmetic but was suppressed via
  a temporary `:logger` primary filter, since a real deployment's log
  output shouldn't include a false-alarm stack trace on every boot.

### Phase 0.5 — pure-Erlang Cowboy release, no Elixir anywhere (PASS)

The harder test: a rebar3-shaped Cowboy app with no Elixir, no Mix, no
`opentelemetry_cowboy`/`cowboy_telemetry` dependency, and no
`stream_handlers` configuration at all — as vanilla as a Cowboy service
gets. Same injection surface, same result: an exported HTTP-server span.

- **The Elixir bootstrap-circularity finding above** came from this spike
  (see "Why two modules, not one").
- **"Module loaded" and "application started" are different failure
  modes.** Every instrumentation setup call failed with `{:noproc,
  {:gen_server, :call, [:telemetry_handler_table, ...]}}` until
  `Application.ensure_all_started(:telemetry)` was added explicitly —
  `:telemetry`'s module was loaded, but nothing had started its
  supervisor. Invisible on the Phoenix spike (Phoenix/Bandit/Ecto already
  start `:telemetry` themselves); real on a host with nothing else that
  would. A real bootstrapper needs to start every application whose
  *behavior* (not just modules) it depends on, not assume the host did it.
- **Plain Cowboy can be retrofitted with zero app-side code — the most
  novel individual result.** Cowboy, unlike Phoenix/Bandit, emits no
  `:telemetry` events on its own; `cowboy_telemetry_h` is a stream handler
  normally supplied by the app at `cowboy:start_clear/3` call time. Reading
  `ranch_conns_sup.erl` shows `ranch:get_protocol_options/1` is called
  fresh for *every accepted connection*, not once at listener start — so
  `ranch:set_protocol_options/2`, an ordinary public API call, retrofits
  `cowboy_telemetry_h` onto an already-running listener, live, with zero
  code in the target app. Verified end-to-end: a request made after the
  retrofit produces a real span, against a listener that started with zero
  knowledge any of this would happen. (Same race shape as the endpoint
  race, one layer down: a connection already open when the retrofit runs
  keeps its old, uninstrumented options — new connections pick it up.)
  Skipped automatically when Phoenix is present, since Phoenix's own
  instrumentation already covers the request and retrofitting underneath
  it would double-instrument.

### Phase 2 — OTP version matrix: one distribution build per major, confirmed

The bundle is pure BEAM bytecode, no NIFs — but bytecode is only
forward-incompatible, not just "compatible for a couple of versions" as a
vague caveat. Both spikes were re-run end-to-end against OTP 28.5.0.5 /
Elixir 1.20.2 (this repo's own toolchain) after initially validating on OTP
25 / Elixir 1.17, and passed unmodified on both — but rebuilding the bundle
under OTP 28 and then trying to boot the OTP 25 spike against those same
compiled artifacts crashed immediately with `corrupt atom table` errors
from the OTP 25 VM's module loader. Newer-compiled bytecode does not load
on an older VM. This settles the design question in favor of the Python
auto-instrumentation image's approach: a real distribution needs one build
per supported OTP major, published separately, not a single "newest wins"
artifact.

### Phase 3 — coverage expansion, and a real scoping criterion

Attempting to add `opentelemetry_req` (Req HTTP client tracing) the same
way as everything above — detect, call `setup()` — surfaced two problems
that don't apply to Phoenix/Bandit/Cowboy/Ecto, and together give the SIG
a concrete criterion for the open scoping question below, not just a
hand-wave toward "grow incrementally."

1. Req has no global `:telemetry`-shaped switch to flip; `OpentelemetryReq`
   instruments one `%Req.Request{}` at a time. It does expose a different
   global hook — `Req.new/1` runs a `:plugins` list pulled from
   `Req.default_options/0` — so
   `Req.default_options(plugins: [OpentelemetryReq | existing])`
   retroactively instruments every subsequent `Req.new/1` call process-wide,
   merged in without clobbering anything the host already configured.
2. `opentelemetry_phoenix`/`opentelemetry_bandit` declare their target
   library as a dev/test-only dependency, so this bundle never carries its
   own copy — `Code.ensure_loaded?/1` alone reliably means "the host has
   this." `opentelemetry_req` declares `req` as a normal dependency, so the
   bundle transitively loads Req's own modules regardless of whether the
   target host uses Req — the same detection check would report "in use"
   on every release. Fixed by snapshotting `application:loaded_applications()`
   before phase 0/1 touches anything, so the Elixir layer can tell "the
   host's own boot already had this" apart from "this bundle's own
   dependency closure happened to load it."

Verified both directions end to end, symmetric with the Cowboy retrofit's
own two-sided verification: a host with a real Req dependency gets a real
client span with zero code of its own; a host with no Req in its
dependency tree — despite this bundle transitively loading Req's modules
onto it regardless — correctly never claims the instrumentation is active.

This distinction — `:telemetry`-event-based vs. per-instance opt-in;
optional-dependency vs. hard-dependency contrib package — is a real,
checkable criterion for scoping future coverage, not just a judgment call
per library.

## Open question

One gap remains deliberately unresolved by these spikes, and is the right
place for SIG input before an implementation lands:

- **Distribution scope and ownership.** Should the bundle attempt to cover
  every `opentelemetry-erlang-contrib` instrumentation, or ship a
  deliberately small v0 (Phoenix/Bandit/Cowboy/Ecto/Req, as spiked) and grow
  incrementally — using the Phase 3 criterion above (telemetry-event-based
  and optional-dependency contrib packages fit the existing pattern
  directly; per-instance-opt-in and hard-dependency packages need their own
  mechanism evaluated case by case)? Should `otel_auto_bootstrap` live in
  `contrib` itself, so it's versioned alongside the instrumentations it
  activates? And now that "one build per OTP major" is confirmed necessary
  rather than merely prudent, how many majors get supported concurrently,
  and who maintains that build matrix?

## Proposed path

1. **This document**, posted to the SIG (GitHub Discussion and/or the
   `#otel-erlang-elixir` CNCF Slack channel, which holds weekly meetings)
   for design feedback — particularly on bundle scope and where
   `otel_auto_bootstrap` should live.
2. **`opentelemetry-erlang-contrib`**: land the bootstrapper as a real
   package once the design is agreed, with a CI matrix covering the OTP
   version question above.
3. **`opentelemetry-operator`**: add
   `instrumentation.opentelemetry.io/inject-erlang` (initContainer +
   webhook env mutation), following the pattern of the in-flight PHP
   support (operator PR #5220) and the already-merged Instrumentation
   v1beta1 RFC, which explicitly treats new-language support as
   incremental.

## Appendix: reproducing the spikes

See [`README.md`](./README.md) for full command-by-command instructions.
Short version, from the repository root:

```sh
mix deps.get && MIX_ENV=prod mix compile   # this package

cd vanilla_app && mix deps.get && MIX_ENV=prod mix release --overwrite
cd ..

./run_spike.sh          # Phase 0 + round 2 hardening: Phoenix + Ecto, mix release
./run_spike_erlang.sh   # Phase 0.5: plain Cowboy, pure-Erlang release, no Elixir/Mix
```
