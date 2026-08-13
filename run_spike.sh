#!/usr/bin/env bash
# Phase 0 spike: zero-code OpenTelemetry instrumentation of a vanilla
# Phoenix mix release, from entirely outside the release.
#
# The vanilla release is started EXACTLY as built — the only delta is
# environment variables, which is precisely what a Kubernetes mutating
# webhook injects. No mix.exs change, no source change, no rebuild.
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE="$SPIKE_DIR/vanilla_app/_build/prod/rel/vanilla_app/bin/vanilla_app"
BUNDLE_LIB="$SPIKE_DIR/_build/prod/lib"
OUT_DIR="${SPIKE_OUT_DIR:-/tmp/otel-spike}"
APP_PORT="${APP_PORT:-4000}"
COLLECTOR_PORT="${COLLECTOR_PORT:-4318}"
RACE_BURST="${RACE_BURST:-10}"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/app.log "$OUT_DIR"/collector.log "$OUT_DIR"/vanilla_app.db

# Stage the "shared volume" the way the Operator's initContainer would:
# the bundle's applications PLUS the OTP library applications a pruned
# mix release does not ship but the OTLP exporter needs (:inets today).
# A real autoinstrumentation-erlang image would bake these in at build time.
DIST="$OUT_DIR/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -r "$BUNDLE_LIB"/. "$DIST/"
ERL_ROOT=$(erl -noshell -eval 'io:format("~s",[code:root_dir()]),init:stop()')
for otp_app in inets; do
  cp -r "$ERL_ROOT"/lib/${otp_app}-* "$DIST/"
done
BUNDLE_LIB="$DIST"

echo "==> starting fake OTLP collector on :$COLLECTOR_PORT"
PORT="$COLLECTOR_PORT" elixir "$SPIKE_DIR/fake_collector.exs" > "$OUT_DIR/collector.log" 2>&1 &
COLLECTOR_PID=$!

cleanup() {
  kill "$COLLECTOR_PID" 2>/dev/null || true
  "$RELEASE" stop > /dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1

echo "==> starting vanilla release with external OTel injection"
# ---- This block is the whole experiment: what the Operator would inject ----
# ERL_LIBS does NOT work here: mix releases boot in embedded mode, which
# ignores it entirely (verified). -pa is honored in every mode, so the
# injection surface is one -pa for the bootstrapper plus one -eval; the
# bootstrapper grafts the rest of the bundle onto the code path itself.
export ERL_AFLAGS="-pa $BUNDLE_LIB/otel_auto_bootstrap/ebin -eval code:load_file(otel_auto_bootstrap_shim),otel_auto_bootstrap_shim:start()"
export OTEL_AUTO_BUNDLE_LIB="$BUNDLE_LIB"
export OTEL_SERVICE_NAME="vanilla-app-spike"
export OTEL_TRACES_EXPORTER="otlp"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$COLLECTOR_PORT"
export OTEL_BSP_SCHEDULE_DELAY="500"
# ---------------------------------------------------------------------------
export PORT="$APP_PORT"
export DB_PATH="$OUT_DIR/vanilla_app.db"

"$RELEASE" start > "$OUT_DIR/app.log" 2>&1 &

echo "==> waiting for endpoint"
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$APP_PORT/items" > /dev/null 2>&1; then break; fi
  sleep 1
done

echo "==> race-window diagnostic: firing $RACE_BURST concurrent requests at first readiness"
# This measures the structural startup race documented in
# otel_auto_bootstrap.ex: the endpoint is already accepting connections
# before -eval attaches instrumentation, and no command-line boot hook can
# close that window (verified separately: -run has the same ordering as
# -eval). Firing a burst immediately at readiness — with no grace sleep —
# shows how many of those requests land before/after attachment completes.
# `wait` (no args) would block on every background job in this shell,
# including the release and collector — so the burst's PIDs are collected
# and waited on explicitly instead.
RACE_PIDS=()
for _ in $(seq 1 "$RACE_BURST"); do
  curl -sf "http://127.0.0.1:$APP_PORT/items" > /dev/null &
  RACE_PIDS+=("$!")
done
# Guard against RACE_BURST=0: an empty "${RACE_PIDS[@]}" expands to nothing,
# which degenerates `wait` back into "wait on every background job" —
# including the release and collector — exactly the bug this was meant to
# avoid.
if [ "${#RACE_PIDS[@]}" -gt 0 ]; then
  wait "${RACE_PIDS[@]}"
fi

# The race-burst above is diagnostic ONLY — it deliberately races
# instrumentation attachment and some/all of it is expected to land
# untraced. The main pass/fail assertion needs a clean signal, so it gets
# the grace period back: enough time for the bootstrapper (typically
# sub-second; see app.log timestamps) to finish attaching before these
# requests are issued.
sleep 2

echo "==> issuing the two requests the main assertion checks"
curl -sf "http://127.0.0.1:$APP_PORT/items"
echo
curl -sf "http://127.0.0.1:$APP_PORT/items" > /dev/null

echo "==> issuing a request that exercises the Req client instrumentation"
# vanilla_app never imports or calls OpentelemetryReq — see
# ItemController.outbound/2. Its Req client is built fresh on every
# request (Req.new/1 re-reads the current global default_options each
# time), so — unlike the Cowboy retrofit's per-CONNECTION race — this one
# only needs the same grace period already elapsed above, not its own.
curl -sf "http://127.0.0.1:$APP_PORT/outbound" > /dev/null

echo "==> issuing a request that exercises the Oban job instrumentation"
# vanilla_app never imports or calls OpentelemetryOban — see
# ItemController.jobs/2. Unlike /outbound, this only enqueues a job; Oban's
# own queue picks it up asynchronously (default poll/stage interval is
# sub-second), well within the export wait below.
curl -sf "http://127.0.0.1:$APP_PORT/jobs" > /dev/null

echo "==> waiting for span export (batch processor delay) and Oban job execution"
sleep 10

echo
echo "===== app.log ====="
cat "$OUT_DIR/app.log"
echo
echo "===== collector.log ====="
cat "$OUT_DIR/collector.log"

# `|| true` guards the whole pipe: under `pipefail`, grep finding zero
# matches (a legitimate "0 spans traced" outcome, not a script error) would
# otherwise make this assignment's exit status 1 and abort the script here
# under `set -e`, even though cut/awk both succeed.
TOTAL_TRACED=$( (grep -o 'span_count=[0-9]*' "$OUT_DIR/collector.log" | cut -d= -f2 | awk '{s+=$1} END {print s+0}') || true)
TOTAL_TRACED="${TOTAL_TRACED:-0}"
TOTAL_SENT=$((RACE_BURST + 2))
echo
echo "===== race-window diagnostic ====="
echo "requests sent (burst-at-readiness + main assertion): $TOTAL_SENT"
echo "GET /items spans observed by collector:               $TOTAL_TRACED"
echo "(a gap here is the structural startup race documented in otel_auto_bootstrap.ex —"
echo " requests served before -eval attaches instrumentation are never traced)"

echo
if grep -q 'POST /v1/traces' "$OUT_DIR/collector.log" &&
   grep -q 'GET /items' "$OUT_DIR/collector.log" &&
   grep -q 'vanilla_app.repo.query' "$OUT_DIR/collector.log" &&
   grep -q 'internal.invalid' "$OUT_DIR/collector.log" &&
   grep -q 'process default' "$OUT_DIR/collector.log" &&
   grep -q 'vanilla-app-spike' "$OUT_DIR/collector.log"; then
  echo "SPIKE RESULT: PASS — Phoenix + Ecto + Req + Oban spans exported over OTLP from an unmodified release"
else
  echo "SPIKE RESULT: FAIL — expected spans did not reach the collector"
  exit 1
fi

if [ "${SKIP_IDEMPOTENCY_CHECK:-0}" = "1" ]; then
  exit 0
fi

echo
echo "==> idempotency diagnostic: simulating reboot_system_after_config (double -eval)"
IDEMPOTENCY_PORT=$((APP_PORT + 1))
export PORT="$IDEMPOTENCY_PORT"
export DB_PATH="$OUT_DIR/vanilla_app_idempotency.db"
DOUBLE_EVAL="code:load_file(otel_auto_bootstrap_shim),otel_auto_bootstrap_shim:start(),otel_auto_bootstrap_shim:start()"
export ERL_AFLAGS="-pa $BUNDLE_LIB/otel_auto_bootstrap/ebin -eval $DOUBLE_EVAL"
# The main assertion's release instance is still running (stopped only by
# the EXIT trap at the very end) — a distinct node name is required so this
# second instance doesn't collide with it over distributed Erlang. Set only
# for these two commands (not exported) so the EXIT trap's cleanup, which
# runs later and targets the main instance, is unaffected.
IDEMPOTENCY_NODE="vanilla_app_idempotency@$(hostname)"
RELEASE_NODE="$IDEMPOTENCY_NODE" "$RELEASE" start > "$OUT_DIR/idempotency.log" 2>&1 &

for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$IDEMPOTENCY_PORT/items" > /dev/null 2>&1; then break; fi
  sleep 1
done
sleep 1
RELEASE_NODE="$IDEMPOTENCY_NODE" "$RELEASE" stop > /dev/null 2>&1 || true

echo "===== idempotency.log ====="
cat "$OUT_DIR/idempotency.log"

STARTED_COUNT=$(grep -c 'SDK started' "$OUT_DIR/idempotency.log" || true)
SKIPPED_COUNT=$(grep -c 'already bootstrapped' "$OUT_DIR/idempotency.log" || true)

echo
if [ "$STARTED_COUNT" = "1" ] && [ "$SKIPPED_COUNT" = "1" ]; then
  echo "IDEMPOTENCY RESULT: PASS — bootstrap ran exactly once across two start() calls"
else
  echo "IDEMPOTENCY RESULT: FAIL — expected 1 SDK start + 1 skip, got started=$STARTED_COUNT skipped=$SKIPPED_COUNT"
  exit 1
fi
