#!/usr/bin/env bash
# Phase 0.5 spike: zero-code OpenTelemetry instrumentation of a pure-Erlang
# Cowboy release — no Elixir, no Mix, anywhere in the target application.
#
# This tests the two open questions round-1 hardening left unvalidated:
#   1. Can the Elixir-authored bootstrapper self-host its own Elixir
#      runtime (elixir + logger OTP apps) on a host that has none at all?
#   2. Plain Cowboy emits no :telemetry events by itself (unlike Phoenix/
#      Bandit) — can cowboy_telemetry be retrofitted onto an already-
#      running listener from entirely outside, with zero change to the
#      vanilla app?
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SPIKE_DIR/vanilla_app_erlang"
BUNDLE_LIB="$SPIKE_DIR/_build/prod/lib"
OUT_DIR="${SPIKE_OUT_DIR:-/tmp/otel-spike-erlang}"
APP_PORT="${APP_PORT:-4020}"
COLLECTOR_PORT="${COLLECTOR_PORT:-4319}"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/app.log "$OUT_DIR"/collector.log

# Stage the "shared volume": the bundle's applications, PLUS the OTP
# library applications the OTLP exporter needs beyond what this pruned
# release ships (:inets — same as the Phoenix spike), PLUS :elixir and
# :logger themselves. This host has never run Elixir; the bootstrapper is
# Elixir bytecode, so its own runtime has to travel in the bundle too.
DIST="$OUT_DIR/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -r "$BUNDLE_LIB"/. "$DIST/"
# :compiler is a runtime dependency of Elixir's own :elixir application
# (Code/Macro eval machinery) — missing it isn't a "module failed to load"
# case like the others, it's "not on the code path at all", surfaced as
# `{error, {compiler, {"no such file or directory", "compiler.app"}}}`
# from Application.ensure_all_started/1.
ERL_ROOT=$(erl -noshell -eval 'io:format("~s",[code:root_dir()]),init:stop()')
for otp_app in inets compiler; do
  cp -r "$ERL_ROOT"/lib/${otp_app}-* "$DIST/"
done
# elixir + logger ship with the Elixir installation, not with Erlang/OTP.
ELIXIR_LIB_ROOT="$(dirname "$(command -v elixir)")/../lib"
cp -r "$ELIXIR_LIB_ROOT/elixir" "$DIST/"
cp -r "$ELIXIR_LIB_ROOT/logger" "$DIST/"
BUNDLE_LIB="$DIST"

echo "==> starting fake OTLP collector on :$COLLECTOR_PORT"
PORT="$COLLECTOR_PORT" elixir "$SPIKE_DIR/fake_collector.exs" > "$OUT_DIR/collector.log" 2>&1 &
COLLECTOR_PID=$!

cleanup() {
  kill "$COLLECTOR_PID" 2>/dev/null || true
  pkill -9 -f "sname vanilla_erl_spike" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

echo "==> compiling the pure-Erlang app with whatever erlc is on PATH"
cd "$APP_DIR"
rm -rf ebin
mkdir -p ebin
erlc -o ebin src/*.erl
cp src/vanilla_app_erlang.app.src ebin/vanilla_app_erlang.app

echo "==> generating .rel + boot script for the pure-Erlang release (no Elixir, no Mix)"
# The .rel file's application versions are NOT hardcoded — they're read
# from whatever OTP/cowboy/cowlib/ranch is actually on the code path at
# generation time. This, plus recompiling with whatever erlc is active
# above, is what makes the same vanilla_app_erlang source buildable
# against any OTP major (validated against OTP 25 and OTP 28 in this
# repo) without editing anything by hand.
rm -f ./*.boot ./*.script ./*.rel
erl -noshell \
  -pa ebin \
  -pa "$SPIKE_DIR/_build/prod/lib/cowboy/ebin" \
  -pa "$SPIKE_DIR/_build/prod/lib/cowlib/ebin" \
  -pa "$SPIKE_DIR/_build/prod/lib/ranch/ebin" \
  -eval '
    Apps = [kernel, stdlib, crypto, asn1, public_key, ssl, ranch, cowlib, cowboy],
    AppEntries = lists:map(
      fun(App) ->
        ok = case application:load(App) of
          ok -> ok;
          {error, {already_loaded, App}} -> ok
        end,
        {ok, Vsn} = application:get_key(App, vsn),
        {App, Vsn}
      end,
      Apps
    ),
    ok = application:load(vanilla_app_erlang),
    {ok, AppVsn} = application:get_key(vanilla_app_erlang, vsn),
    RelEntries = AppEntries ++ [{vanilla_app_erlang, AppVsn, permanent}],
    ErtsVsn = erlang:system_info(version),
    Rel = {release, {"vanilla_app_erlang", AppVsn}, {erts, ErtsVsn}, RelEntries},
    ok = file:write_file("vanilla_app_erlang.rel", io_lib:format("~p.~n", [Rel])),
    io:format("wrote .rel for erts ~s: ~p~n", [ErtsVsn, RelEntries]),
    case systools:make_script("vanilla_app_erlang", [local, {outdir, "."}]) of
      ok -> io:format("boot script OK~n");
      Error -> io:format("boot script ERR: ~p~n",[Error]), halt(1)
    end,
    init:stop().
  '

echo "==> starting vanilla release with external OTel injection"
# ---- This block is the whole experiment: what the Operator would inject ----
export ERL_AFLAGS="-pa $BUNDLE_LIB/otel_auto_bootstrap/ebin -eval code:load_file(otel_auto_bootstrap_shim),otel_auto_bootstrap_shim:start()"
export OTEL_AUTO_BUNDLE_LIB="$BUNDLE_LIB"
export OTEL_SERVICE_NAME="vanilla-app-erlang-spike"
export OTEL_TRACES_EXPORTER="otlp"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$COLLECTOR_PORT"
export OTEL_BSP_SCHEDULE_DELAY="500"
# ---------------------------------------------------------------------------
export PORT="$APP_PORT"

PORT="$APP_PORT" erl -noshell -mode embedded \
  -pa ebin \
  -pa "$SPIKE_DIR/_build/prod/lib/cowboy/ebin" \
  -pa "$SPIKE_DIR/_build/prod/lib/cowlib/ebin" \
  -pa "$SPIKE_DIR/_build/prod/lib/ranch/ebin" \
  -boot ./vanilla_app_erlang \
  -sname vanilla_erl_spike \
  > "$OUT_DIR/app.log" 2>&1 &

echo "==> waiting for endpoint"
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$APP_PORT/items" > /dev/null 2>&1; then break; fi
  sleep 1
done

# The first request(s) may race the -eval bootstrap AND the cowboy_telemetry
# retrofit (same structural window documented in otel_auto_bootstrap.ex).
# Also: even after the retrofit lands, an HTTP/1.1 keep-alive connection
# opened *before* the retrofit keeps using its original (uninstrumented)
# ranch protocol options — only a fresh connection picks up the change. A
# short grace period plus fresh `curl` invocations (no keep-alive reuse
# across separate curl processes) avoids both races for the main assertion.
sleep 2

echo "==> issuing the request the assertion checks"
curl -sf "http://127.0.0.1:$APP_PORT/items"
echo

echo "==> waiting for span export (batch processor delay)"
sleep 10

echo
echo "===== app.log ====="
cat "$OUT_DIR/app.log"
echo
echo "===== collector.log ====="
cat "$OUT_DIR/collector.log"

echo
# opentelemetry_cowboy names spans after the bare HTTP method (its
# handle_event/4 sets SpanName to just `Method`, e.g. "GET" — the path
# goes into the url.path attribute separately, unlike Phoenix/Bandit's
# "METHOD /path"-style span names) — so the marker here is "items" (from
# that attribute), not "GET /items".
if grep -q 'POST /v1/traces' "$OUT_DIR/collector.log" &&
   grep -q 'items' "$OUT_DIR/collector.log" &&
   grep -q 'vanilla-app-erlang-spike' "$OUT_DIR/collector.log"; then
  echo "SPIKE RESULT: PASS — Cowboy span exported over OTLP from a pure-Erlang release with retrofitted cowboy_telemetry"
else
  echo "SPIKE RESULT: FAIL — expected span did not reach the collector"
  exit 1
fi
