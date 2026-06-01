#!/usr/bin/env bash
# Record ONE demo scenario against a freshly-restarted server, so exactly one
# cold cc-agent has to bind (no ephemeral-agent accumulation / boot-storm).
#
# Usage:
#   DEMO_MODE=chat     DEMO_OUTDIR=/tmp/demo-chat     scripts/demo/record-clean.sh
#   DEMO_MODE=operator DEMO_OUTDIR=/tmp/demo-operator scripts/demo/record-clean.sh
#   DEMO_MODE=soul     DEMO_OUTDIR=/tmp/demo-soul     scripts/demo/record-clean.sh
set -uo pipefail

ROOT="/Users/daiming/workspace/ezagent42/ezagent-poc-phase-2"
SHARED_DEPS="/Users/daiming/workspace/ezagent42/.poc-shared-deps"
NODE="ezagent_runtime_phase2@127.0.0.1"
COOKIE_FILE="$HOME/.ezagent/poc-phase2/runtime/cookie"
MODE="${DEMO_MODE:-chat}"
TENANT="${DEMO_TENANT:-cinnox}"
OUTDIR="${DEMO_OUTDIR:-/tmp/demo-$MODE}"
SRV_LOG="/tmp/poc-server-$MODE.log"
cd "$ROOT"

cleanup() {
  echo "[clean] stopping server…"
  local pid; pid=$(lsof -ti tcp:10142 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  sleep 3
  pkill -f 'esr-system-prompt' 2>/dev/null || true
  pkill -f 'append-system-prompt.*esr' 2>/dev/null || true
}
trap cleanup EXIT

# 0. clean slate
cleanup
sleep 1

# 1. start server (distributed) clean
echo "[clean] starting server -> $SRV_LOG"
COOKIE=$(cat "$COOKIE_FILE")
EZAGENT_PROFILE=poc-phase2 PORT=10142 \
  EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket \
  EZAGENT_RUNTIME_NODE="$NODE" \
  MIX_DEPS_PATH="$SHARED_DEPS" \
  env -u USE_LOCAL_OAUTH -u ANTHROPIC_API_KEY -u CLAUDE_CODE_DISABLE_CRON -u USE_STAGING_OAUTH \
  elixir --name "$NODE" --cookie "$COOKIE" -S mix phx.server > "$SRV_LOG" 2>&1 &

# 2. wait for HTTP
echo "[clean] waiting for :10142…"
for i in $(seq 1 45); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:10142/ 2>/dev/null || echo 000)
  [ "$code" = "302" ] || [ "$code" = "200" ] && { echo "[clean] up (HTTP $code) ~$((i*3))s"; break; }
  sleep 3
done

# 3. ensure tenant workspace (idempotent) — also confirms the node is reachable
echo "[clean] ensuring $TENANT workspace…"
sleep 6
TENANT="$TENANT" EZAGENT_RUNTIME_NODE="$NODE" \
  elixir --name "phase2_ensure_$$@127.0.0.1" --cookie "$COOKIE" poc/phase-2/setup.exs 2>&1 | tail -3

# 3b. soul demo: reset sandbox soul override so before/after starts from baseline
if [ "$MODE" = "soul" ]; then
  echo "[clean] resetting $TENANT sandbox soul override (baseline)…"
  rm -f "$HOME/poc-sandbox-phase2/$TENANT/souls/customer.md" \
        "$HOME/poc-sandbox-phase2/$TENANT/souls/customer.prev.md" 2>/dev/null || true
fi

# 4. record (prewarm 1 cold agent + drive + convert)
echo "[clean] recording mode=$MODE tenant=$TENANT -> $OUTDIR"
DEMO_MODE="$MODE" DEMO_TENANT="$TENANT" DEMO_OUTDIR="$OUTDIR" "$ROOT/scripts/demo/record-scenario.sh"
rc=$?

echo "[clean] mode=$MODE finished rc=$rc"
exit $rc
