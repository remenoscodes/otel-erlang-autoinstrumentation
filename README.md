# Zero-code OpenTelemetry auto-instrumentation for BEAM releases

[![spikes](https://github.com/remenoscodes/otel-erlang-autoinstrumentation/actions/workflows/spikes.yml/badge.svg)](https://github.com/remenoscodes/otel-erlang-autoinstrumentation/actions/workflows/spikes.yml)
License: [Apache 2.0](./LICENSE)

**Status: PASS on both tested hosts.** A production-style Phoenix
`mix release` containing **zero OpenTelemetry code** was instrumented
entirely from outside the release, exporting Phoenix + Ecto spans over
OTLP/HTTP without touching `mix.exs`, application source, or the build
(Phase 0). A pure-Erlang Cowboy release with **no Elixir, no Mix, and no
telemetry dependency at all** was instrumented the same way, including a
live retrofit of `cowboy_telemetry` onto an already-running listener
(Phase 0.5, below).

This package is the payload half of a plan to bring Erlang/Elixir support to
the [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)'s
auto-instrumentation matrix (`inject-erlang`), following the same
architecture the Operator uses for Java/Node/Python/.NET/Go and that PHP is
currently landing: initContainer copies an instrumentation payload into a
shared volume, and a mutating webhook alters only the pod's environment.
See [`PROPOSAL.md`](./PROPOSAL.md) for the full design and the path to get
there.

## Installation

Not yet published to Hex. Once it is:

```elixir
def deps do
  [{:otel_auto_bootstrap, "~> 0.1.0"}]
end
```

In the meantime, install from GitHub:

```elixir
def deps do
  [{:otel_auto_bootstrap, github: "remenoscodes/otel-erlang-autoinstrumentation"}]
end
```

Ordinary Mix-dependency installation is for local development/testing of
this package only, though — the whole point of the design (see
"Layout" and `PROPOSAL.md`) is that the *target* application never depends
on this package at all. It's meant to be compiled once into a distribution
image and mounted into the target release from outside via an
initContainer, exactly like the Operator's existing Java/Python/Node/.NET/Go
support. `run_spike.sh`/`run_spike_erlang.sh` show that mechanism end to
end.

## Layout

```
lib/, src/, mix.exs    The package itself (:otel_auto_bootstrap on Hex): the
                      OTel SDK, OTLP exporter, contrib instrumentations
                      (phoenix, bandit, ecto, cowboy) as deps, plus the two
                      modules that activate everything inside a foreign,
                      already-booted release — otel_auto_bootstrap_shim.erl
                      (phase 0/1, plain Erlang) and OtelAutoBootstrap (phase
                      2/3, Elixir). See both modules' moduledocs for why
                      that split exists.

vanilla_app/           Integration test fixture: Phoenix 1.7 + Bandit + Ecto
                      (SQLite) app, built with `mix release`. Deliberately
                      contains NO otel deps.
vanilla_app_erlang/    Integration test fixture: plain Cowboy, no Elixir, no
                      Mix, no telemetry dependency at all.
fake_collector.exs    Minimal OTLP/HTTP receiver used by both integration
                      scripts below; logs which span names arrive (span
                      names travel as plain bytes in protobuf).
run_spike.sh           Builds vanilla_app + this package, then instruments
                      the former from outside and asserts real spans reach
                      fake_collector.exs. Phases 0, 2 (round 2 hardening),
                      and the OTP version-matrix check.
run_spike_erlang.sh    Same, against vanilla_app_erlang. Phase 0.5.
test/                  Unit tests for the package's testable pure logic —
                      NOT a substitute for the two integration scripts
                      above, which are what actually prove the zero-code
                      claim end-to-end against a real release boot.
```

The *entire* injection surface — what a Kubernetes mutating webhook would
add to the pod spec — is environment variables:

```sh
ERL_AFLAGS="-pa <bundle>/otel_auto_bootstrap/ebin -eval code:load_file(otel_auto_bootstrap_shim),otel_auto_bootstrap_shim:start()"
OTEL_AUTO_BUNDLE_LIB=<bundle>
OTEL_SERVICE_NAME=...
OTEL_EXPORTER_OTLP_ENDPOINT=...
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_EXPORTER=otlp
```

Result (reproducible via `./run_spike.sh`):

```
[otel_auto_bootstrap] starting; code mode: :embedded
[otel_auto_bootstrap] prepared 35 applications (bundle + dependency closure)
[otel_auto_bootstrap] SDK started (apps: [:inets, ..., :opentelemetry])
[otel_auto_bootstrap] instrumentation active: bandit
[otel_auto_bootstrap] instrumentation active: phoenix
[otel_auto_bootstrap] instrumentation active: ecto VanillaApp.Repo prefix=[:vanilla_app, :repo]
[collector] POST /v1/traces body=2610 bytes
            markers=["GET /items", "vanilla_app.repo.query", "vanilla-app-spike"]
SPIKE RESULT: PASS
```

The HTTP server span, the Ecto query span, and the injected
`service.name` resource attribute all reached the collector.

## Findings — what the real bootstrapper must know

These are the load-bearing discoveries; each one shaped the design and was
verified experimentally against OTP 25 / Elixir 1.17.

1. **`ERL_LIBS` is ignored in embedded mode.** Mix releases boot with
   `-mode embedded`, and in that mode the code server never adds `ERL_LIBS`
   directories to the code path (verified: `code:get_path/0` shows nothing).
   The naive "mount volume + set ERL_LIBS" design does not work for
   production releases. **`-pa` (via `ERL_AFLAGS`) works in every mode** and
   is the correct primitive.

2. **Keep the injected surface minimal: one `-pa`, one `-eval`.** Only
   `otel_auto_bootstrap_shim`'s own `ebin` goes on `-pa`; the shim grafts the
   rest of the bundle onto the code path itself (`code:add_pathz/1`). This
   keeps the webhook payload independent of bundle contents/versions. (The
   shim, not `OtelAutoBootstrap`, owns this step — see "Phase 0.5" below for
   why that split matters, not just where the code happens to live.)

3. **`erlexec` strips quote characters from `ERL_AFLAGS`.** An `-eval`
   expression containing quoted atoms (`'Elixir.Foo'`) gets mangled into a
   syntax error. The entry point must be an Erlang-named module so the
   injected expression is quote-free:
   `code:load_file(otel_auto_bootstrap_shim),otel_auto_bootstrap_shim:start()`.

4. **Embedded mode never loads modules on demand**, so the bootstrapper must
   explicitly `code:load_file/1` every module of every application it brings
   in. `application:ensure_all_started/1` alone is not sufficient.

5. **The bundle must carry more than the otel apps.** A pruned release omits
   OTP library applications its own code doesn't use — the OTLP exporter
   needs `:inets`, which the vanilla release did not ship. The bootstrapper
   walks the full `applications` dependency closure of the bundle and loads
   whatever the release doesn't already provide; the distribution image must
   include those OTP library apps.

6. **Module loading needs multiple passes.** `-on_load` hooks may call
   sibling modules of the same app (`tls_certificate_check` does), so a
   module can fail to load until the rest of its application is loaded.
   A fixpoint retry loop resolves this. (`code:atomic_load/1` is not an
   option: it rejects modules with on_load hooks.)

7. **Dependency collision has a clean default policy.** The release's own
   copies of shared deps (`telemetry`, `plug`, ...) stay authoritative for
   free: their modules are already loaded (embedded boot), the bootstrapper
   only loads modules that aren't, and bundle paths are *appended* so the
   release wins any path lookup. The bundle's copies serve only releases
   that lack the dep.

8. **Ecto repos are discoverable at runtime with zero configuration.**
   `Ecto.Repo.all_running/0` enumerates started repos, and each repo's
   `config()[:telemetry_prefix]` yields exactly what
   `OpentelemetryEcto.setup/1` needs. The spike auto-discovered
   `VanillaApp.Repo` with prefix `[:vanilla_app, :repo]`.

9. **Timing works out.** `-eval` expressions run after the boot script has
   started all release applications, so the bootstrapper sees the running
   system (endpoint up, repos registered) — right when detection needs it.
   It spawns and never blocks or crashes init; every failure degrades to a
   log line.

## Hardening pass (round 2)

Four gaps from the first pass were investigated further; `run_spike.sh` now
exercises two of them directly and gates on both:

- **Startup race — confirmed structural, now quantified.** Tested whether
  `-run` (instead of `-eval`) could attach instrumentation before the
  release's applications start: it cannot. Both are processed by `init`
  only *after* the boot script has already applied
  `{apply, {application, start_boot, [App, permanent]}}` for every release
  application — confirmed by comparing log timestamps for both hooks, and
  independently by making `-run` fail (undefined function) and observing
  the Phoenix endpoint's "Running ..." line had *already* printed before
  the crash. There is no command-line boot hook that runs before permanent
  application start; closing this window would require intercepting the
  boot script itself (a rebuild, not an injection), which is out of scope
  for zero-code. `run_spike.sh` now quantifies the window directly: it
  fires a burst of concurrent requests at the instant the endpoint becomes
  reachable, with no grace period, and counts how many landed traced.
  Measured result: **0 of 10** burst requests were traced (all arrived
  before the bootstrapper finished attaching handlers, which took ~750ms
  end-to-end in this environment), while both of the main assertion's
  requests — issued after a short grace period — were traced. This
  replaces the earlier, unmeasured "~100ms" guess with a real number and
  confirms the window is bounded by bootstrap completion time, not by
  anything unbounded.
- **on_load noise — fixed.** The error/warning reports the code server logs
  while `tls_certificate_check`'s `-on_load` hook fails on its first pass
  (see finding 6) are now suppressed via a temporary `:logger` primary
  filter installed only for the duration of module loading. Verified: the
  scary `** (UndefinedFunctionError) ...` report no longer appears in
  `app.log`, while unrelated log output in the same window is untouched.
- **Idempotency — implemented and tested.** `OtelAutoBootstrap.start/0` now
  guards against double invocation with a `:persistent_term` flag set
  *synchronously* before the async bootstrap is spawned (so a second,
  immediately-following call — including one issued before the first
  call's spawned process has logged anything — always sees the flag).
  `run_spike.sh` simulates `reboot_system_after_config: true` by invoking
  `start()` twice back-to-back in the same `-eval` expression, against a
  second release instance (its own node name, to avoid colliding with the
  main instance's distributed-Erlang name) and a separate SQLite database
  (`pool_size: 1`, so two instances can't share one anyway). Verified: the
  SDK starts exactly once and the second call logs a skip, every run.
- **OTP version matrix**: still open, unchanged — see "Known gaps" below.
- **Pure-Erlang hosts**: was open after round 1 — now validated. See
  "Phase 0.5" below.

### A meta-finding from hardening the test harness itself

Two of the three bugs hit while building the harder tests were bash
scripting bugs, not bootstrapper bugs — worth naming since they'd bite
anyone extending this spike:

- unqualified `wait` (no args) blocks on *every* background job in the
  shell, not just the ones just launched — it silently waited on the
  release and collector processes too, hanging the script.
- under `set -o pipefail`, `grep -o pattern file | cut ... | awk ...`
  aborts the whole script (via `set -e`) when `grep` finds zero matches,
  even though every later stage in the pipe succeeds — "no spans yet" is a
  legitimate outcome, not a script error, so the pipeline needs an explicit
  `|| true`.

## Phase 0.5: pure-Erlang host validation

Round 2 left two questions explicitly open: does the bundle work on a host
with no Elixir at all, and can plain Cowboy (which — unlike Phoenix/Bandit —
emits no `:telemetry` events on its own) be instrumented with zero code at
all? `vanilla_app_erlang/` (a rebar3-project-shaped, but hand-boot-scripted —
see below — pure-Erlang Cowboy app: no Elixir, no Mix, no
`opentelemetry_cowboy`/`cowboy_telemetry` dependency, no `stream_handlers`
override) plus `run_spike_erlang.sh` answer both. **Status: PASS**,
reproducible.

```
[otel_auto_bootstrap] starting; code mode: embedded
[otel_auto_bootstrap] prepared 40 applications (bundle + dependency closure)
[otel_auto_bootstrap] SDK started (apps: [..., :compiler, :elixir, ...])
[otel_auto_bootstrap] retrofitted cowboy_telemetry_h onto ranch listener :vanilla_http (default stream_handlers)
[otel_auto_bootstrap] instrumentation active: cowboy
[collector] POST /v1/traces body=797 bytes markers=["items", "vanilla-app-erlang-spike"]
SPIKE RESULT: PASS
```

### Finding: instrumentation code cannot bootstrap its own runtime

The first attempt crashed immediately: `{undef, ['Elixir.Kernel', inspect,
...]}`. The bootstrapper (`OtelAutoBootstrap`) is Elixir bytecode — even a
log line desugars to `Kernel`/`String.Chars` calls — and on a mix release
host that's a non-issue, because the release IS an Elixir app and Kernel is
already loaded before `-eval` ever runs. On a pure-Erlang host there is no
Elixir runtime for Elixir code to lean on until *something* loads it — and
that something cannot itself be the Elixir code trying to do the loading.

The fix is an architecture split, not a patch: `otel_auto_bootstrap_shim`
(plain Erlang — needs nothing but kernel/stdlib, which every BEAM node has)
now owns everything that used to be "phase 1" — code-path setup and
explicit, multi-pass module loading of the bundle's full dependency closure
— and only *after* that's done does it call `'Elixir.OtelAutoBootstrap':run/0`
for the SDK-start and instrumentation-detection work that legitimately
benefits from being Elixir. By the time that call happens, `elixir` and
`logger` (bundle-shipped on a host that has none, same as `:inets` already
was) have been loaded like any other bundle app, so calling into Kernel is
safe. This changes nothing about the mix-release case — the split is
invisible there, since Kernel was always already loaded — but it's the
difference between working and not working on a host with no Elixir.

One more OTP library app had to join the staged bundle for this host,
found the same way `:inets` was in round 1 (a `{error, {App, "no such file
or directory"}}` from `Application.ensure_all_started/1`, since the app
isn't even on the code path, as opposed to a load failure for something
that is): `:compiler`, a runtime dependency of `:elixir` itself.

`:eex` is referenced by `:elixir`'s optional deps too, and shows up as a
"cannot load app spec for eex" warning during the dependency-closure walk
— but it was never actually staged (only `:elixir`/`:logger` are copied;
`:eex` isn't). That every spike run still passes, on both OTP majors
tested, is itself the answer to whether it's load-bearing: it isn't, for
this scenario. See "Known gaps" below for the (narrow) remaining caveat.

### Finding: loaded-but-not-started is a different failure mode

Getting past the Kernel crash led straight to a second one: every
instrumentation setup call failed with `{:noproc, {:gen_server, :call,
[:telemetry_handler_table, ...]}}`. `:telemetry`'s module was loaded (phase
0/1 handled that), but its application was never *started* — no supervisor,
no `telemetry_handler_table` gen_server. On the Phoenix spike this is
invisible because Phoenix/Bandit/Ecto already depend on and start
`:telemetry` as part of their own supervision tree; a pure-Erlang host has
nothing else that would. Fixed with one line —
`Application.ensure_all_started(:telemetry)` — added to `OtelAutoBootstrap.run/0`
before SDK start. Filed here as a distinct finding because "module loaded"
and "application started" look identical from `Code.ensure_loaded?/1` but
fail in unrelated ways; a bootstrapper for other BEAM libraries with
gen_server-backed setup (not just `:telemetry`) should expect the same
split.

### Finding: plain Cowboy can be retrofitted with zero app-side code

This is the more novel result. Cowboy, unlike Phoenix/Bandit, does not emit
`:telemetry` events on its own — `cowboy_telemetry_h` is a *stream handler*
that has to be present in a listener's `stream_handlers` option, normally
supplied at `cowboy:start_clear/3` call time by the app itself. A genuinely
vanilla Cowboy app (this spike's `vanilla_app_erlang`) has no reason to have
ever added it, and unlike the Phoenix/Ecto case there's no telemetry-prefix
config to discover — there's no telemetry at all yet.

Read `ranch_conns_sup.erl` before attempting anything here: it calls
`ranch_server:get_protocol_options/1` fresh for *every accepted connection*,
not once at listener start. That means `ranch:set_protocol_options/2` —
a public, ordinary API call — changes what *new* connections get, live,
without touching the running listener process at all. `OtelAutoBootstrap`
now does exactly this for every plain-Cowboy listener found via
`:ranch.info/0`: reads the current protocol options, prepends
`:cowboy_telemetry_h` to `:stream_handlers` (reproducing Cowboy's own
`[cowboy_stream_h]` default first, if the key was never set — which it
wasn't here), and writes it back. Verified end-to-end: a request made after
the retrofit produces a real `[cowboy, request, start/stop]` telemetry
event and a real exported span, against a listener that started with zero
knowledge of any of this.

This has the same shape as the `-eval` startup race, one layer down: a
connection already open when the retrofit runs keeps its original,
uninstrumented options (this is why `run_spike_erlang.sh`'s assertion
request, like the Phoenix spike's, runs after a short grace period — each
`curl` invocation is a fresh connection regardless, so this is a smaller
concern here than the endpoint-level race, but the mechanism is identical
and worth naming once).

It only applies when Phoenix isn't present: `OtelAutoBootstrap.setup_cowboy/0`
skips the retrofit entirely if `Phoenix` is loaded, because `setup_phoenix/0`
already covers that request end-to-end — retrofitting cowboy_telemetry
underneath it would double-instrument every request at two layers.

### Getting a pure-Erlang release built at all was its own detour

Not a finding about the bootstrapper, but worth recording so it's not
re-discovered: `rebar3 as prod release` failed two independent ways in this
environment before a release ever booted.

- rebar3's own hex client couldn't resolve `cowboy`/`cowlib` here (a proxy
  quirk unrelated to the spike's actual subject) — worked around by
  symlinking the already-`mix`-fetched sources into `_checkouts/`.
- `relx` then failed with `"Application needed for release not found:
  cowboy"` even with the checkout compiled — not diagnosed further, since
  it made the whole `rebar3 release` path a dead end regardless of the hex
  issue.

`vanilla_app_erlang` is therefore built by hand instead, and
`run_spike_erlang.sh` does it every run: `erlc` for the app's own three
modules, a `.rel` file generated dynamically from whatever's on the live
code path (see "Phase 2" below for why), and `systools:make_script/2` for
the boot script — using the cowboy/cowlib/ranch that `mix compile` already
produced under `_build/prod/lib/` (no separate fetch). This is
no less representative of a real release boot for what this spike tests:
`systools` is the same tool `relx` calls internally, so the boot-script
mechanics (embedded mode, `{path, ...}` + `{primLoad, ...}` instructions)
are identical either way — only the packaging convenience layer is missing.

## Phase 2: OTP version matrix (PASS, with a sharp edge documented)

Both spikes (Phoenix/`mix release` and pure-Erlang/Cowboy) were re-run
end-to-end against **OTP 28.5.0.5 / Elixir 1.20.2** — the toolchain of
`match_os`, the umbrella project this work originated from, built from
source in this environment (no distro/precompiled package was reachable)
since round 1 and round 2 only had OTP 25 / Elixir 1.17 available. Both
passed, unmodified: the same package source, recompiled under OTP 28,
instrumented both vanilla apps exactly as it did under OTP 25.
`vanilla_app_erlang.rel` no longer
hardcodes application versions — `run_spike_erlang.sh` now generates it by
reading each app's actual `vsn` from the live code path at boot-script
generation time, which is what made testing a second OTP major possible
without hand-editing version numbers.

**This is also where the "per-OTP-major build" requirement stopped being
theoretical.** Rebuilding this package under OTP 28 overwrote the same
`_build/prod/lib` directory the OTP 25 spike had been using (both mix
projects share one `_build` path regardless of toolchain — a spike-hygiene
gap worth knowing about, not a bootstrapper issue). Running the OTP 25
spike again against that now-OTP-28-compiled `cowboy`/`ranch`/`cowlib`
crashed immediately:

```
beam/beam_load.c(150): Error loading module ranch: corrupt atom table
init terminating in do_boot ({load_failed,[ranch_acceptor, ...]})
```

Bytecode compiled by a newer OTP major does not load in an older VM. This
had been stated as a plausible risk in round 1 based on general BEAM
bytecode-compatibility knowledge; this is now first-hand evidence of the
actual failure mode, not just the general principle — and it settles the
question the "Open questions" section below still leaves open (distribution
scope), narrowing it specifically to "which direction does compatibility
run": forward-compiled bytecode reliably fails on an older VM, so the
distribution image genuinely needs one build per supported OTP major, not
a single "newest wins" build. (Restoring the OTP 25 build afterward — clean
`mix deps.get` + `mix compile`/`mix release` under OTP 25 — made both
spikes pass again, confirming this was purely the shared-`_build`
collision and not a regression.)

## Known gaps

- **`:eex` is confirmed non-load-bearing for the scenarios tested here** —
  not staged in the bundle at all (only `:elixir`/`:logger` are), yet every
  spike run passes on both OTP majors; the "cannot load app spec for eex"
  warning is cosmetic. This is narrower than "eex is never needed" —
  Phoenix apps that actually render EEx templates presumably do need it —
  but for the plain-Cowboy scenario this repo validates, it's settled.
- **Startup race is structural**, for both the endpoint-level version (any
  release) and the Cowboy-retrofit version (plain-Cowboy hosts) — see the
  moduledoc and the "Phase 0.5" retrofit section above. Not a bug to fix,
  but a permanent property of zero-code injection worth restating here
  since it's the single most load-bearing limitation of the whole approach.
- **Distribution scope and per-OTP-major build ownership** — now that "one
  build per OTP major" is confirmed necessary (see above), this becomes a
  packaging/CI question rather than a technical unknown: how many majors
  to support at once, and how the build matrix gets maintained. Left for
  the SIG discussion in `PROPOSAL.md`.

## Proposed path (unchanged by the spike, now de-risked)

- **Phase 1**: propose the bootstrapper + distribution to the
  OpenTelemetry Erlang/Elixir SIG (`opentelemetry-erlang-contrib`), as the
  BEAM analog of e.g. `opentelemetry-operator`'s Python `autoinstrumentation`
  image contents.
- **Phase 2**: Operator PR adding `instrumentation.opentelemetry.io/inject-erlang`
  (initContainer + env mutation), mirroring the in-flight PHP support
  (operator PR #5220) and the Instrumentation v1beta1 RFC's incremental
  language additions.

## Running it

Requires Erlang/OTP + Elixir + `curl`. From the repository root:

```sh
mix deps.get && MIX_ENV=prod mix compile   # this package

cd vanilla_app && mix deps.get && MIX_ENV=prod mix release --overwrite
cd ..

./run_spike.sh          # Phase 0 + round 2 + OTP matrix: Phoenix + Ecto, mix release
./run_spike_erlang.sh   # Phase 0.5: plain Cowboy, pure-Erlang release, no Elixir/Mix
                        # in the target app (vanilla_app_erlang is built by hand,
                        # by the script itself, on every run)

mix test                 # unit tests for the package's testable pure logic
```
