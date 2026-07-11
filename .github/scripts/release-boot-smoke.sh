#!/usr/bin/env bash
# Boot the assembled prod OTP release in a CLEAN, minimal env and health-probe it.
#
# WHY: the full-suite job runs `mix test` on the self-hosted dev Mac, which carries
# ambient dev conditions the clean deploy container never has (mihomo proxy, a
# populated ~/.claude with tengu_harbor/creds, installed uv/node/claude, a dev
# Postgres, a full PATH). That is how a change can be green in CI yet fail only in
# deploy — the class that caused the #1325 week-long orchestrator outage (the
# esr-bridge sidecar resolved from a build-tree path that `mix release` never
# packaged). This boots the ACTUAL release artifact with NONE of that ambient
# state (env -i + a fresh blank HOME/EZAGENT_HOME), so a container-only failure
# surfaces here instead of in production.
#
# Assumes: `mix release ezagent` already ran (build steps in ci.yml), a Postgres
# service is up on 127.0.0.1:$POSTGRES_PORT, and psql is on PATH (preinstalled on
# the GitHub ubuntu runner).
set -euo pipefail

REL="$PWD/_build/prod/rel/ezagent"
BIN="$REL/bin/ezagent"
[ -x "$BIN" ] || { echo "FATAL: release binary not found at $BIN (did 'mix release' run?)"; exit 1; }

PGUSER="${POSTGRES_USER:-ezagent_pg_compat}"
PGPASS="${POSTGRES_PASSWORD:-ezagent_pg_compat}"
PGHOST="${POSTGRES_HOST:-127.0.0.1}"
PGPORT="${POSTGRES_PORT:-5432}"
DB="ezagent_prod_smoke"
PORT="10042"

# Fresh, throwaway home + release tmp — deliberately EMPTY so the boot/seed path
# runs against a blank profile (no dev ~/.claude, no seeded creds). Mirrors a
# first-boot clean container.
WORK="$(mktemp -d)"
CLEAN_HOME="$WORK/home"
EZ_HOME="$WORK/ezhome"
REL_TMP="$WORK/reltmp"
mkdir -p "$CLEAN_HOME" "$EZ_HOME/default" "$REL_TMP"

SERVER_PID=""
NODE_NAME="ezagent-smoke@127.0.0.1"
cleanup() {
  # Kill the backgrounded server + its BEAM. We do NOT use `bin/ezagent stop`
  # (that needs Erlang distribution, which we deliberately don't rely on here).
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  pkill -f "$NODE_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK" || true
}
trap cleanup EXIT

# Provision the DB the release will migrate (prod has no `mix ecto.create`).
PGPASSWORD="$PGPASS" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null

export SMOKE_DATABASE_URL="ecto://$PGUSER:$PGPASS@$PGHOST:$PGPORT/$DB"
export SMOKE_SKB="$(head -c48 /dev/urandom | base64 | tr -d '\n')"
export SMOKE_COOKIE="release-boot-smoke-cookie"

# Run the release binary with a SCRUBBED environment: `env -i` drops EVERYTHING,
# then we re-add ONLY the minimal set a clean container supplies. Notably absent:
# HTTP_PROXY/HTTPS_PROXY (no proxy), any ANTHROPIC/CLAUDE/dev creds, the dev PATH.
run_clean() {
  env -i \
    PATH="/usr/local/bin:/usr/bin:/bin" \
    HOME="$CLEAN_HOME" \
    LANG="C.UTF-8" LC_ALL="C.UTF-8" \
    TERM="dumb" \
    DATABASE_URL="$SMOKE_DATABASE_URL" \
    SECRET_KEY_BASE="$SMOKE_SKB" \
    PORT="$PORT" \
    PHX_SERVER="true" \
    EZAGENT_HOME="$EZ_HOME" \
    EZAGENT_PROFILE="default" \
    EZAGENT_PUBLIC_HOST="127.0.0.1" \
    EZAGENT_PUBLIC_SCHEME="http" \
    EZAGENT_PUBLIC_PORT="$PORT" \
    RELEASE_DISTRIBUTION="name" \
    RELEASE_NODE="$NODE_NAME" \
    RELEASE_COOKIE="$SMOKE_COOKIE" \
    RELEASE_TMP="$REL_TMP" \
    "$@"
}

echo "== 1/3 migrate (release eval, clean env) =="
run_clean "$BIN" eval "EzagentCore.Release.migrate()"

echo "== 2/3 boot the release (clean env, background) =="
SERVER_LOG="$WORK/server.log"
run_clean "$BIN" start >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

echo "== 3/3 wait for /_health 200 =="
# prod sets start_permanent: true — so if ANY :permanent app fails to start, the
# whole runtime comes down and the node never serves. A /_health 200 therefore
# proves the full supervision tree (every permanent ezagent app + the endpoint)
# booted in this clean, minimal env. That is the deploy-fidelity signal.
ok=0
for i in $(seq 1 90); do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "FATAL: release exited during boot — server log tail:" >&2
    tail -n 80 "$SERVER_LOG" >&2 || true
    exit 1
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/_health" || true)"
  if [ "$code" = "200" ]; then ok=1; echo "  /_health 200 after ${i}s"; break; fi
  sleep 1
done
[ "$ok" = 1 ] || {
  echo "FATAL: /_health never returned 200 — server log tail:" >&2
  tail -n 80 "$SERVER_LOG" >&2 || true
  exit 1
}

# Also fetch `/` — unlike the plain-JSON /_health controller, the root route
# renders through the endpoint's static-manifest pipeline (cache_static_manifest
# from `mix assets.deploy`). A prod asset-manifest break passes /_health but fails
# here. Accept any 2xx/3xx (prod may redirect to a login/home).
root_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
case "$root_code" in
  2??|3??) echo "  / returned $root_code (asset-manifest pipeline OK)" ;;
  *)
    echo "FATAL: / returned $root_code (expected 2xx/3xx) — server log tail:" >&2
    tail -n 80 "$SERVER_LOG" >&2 || true
    exit 1
    ;;
esac

echo "release-boot smoke: PASS"
