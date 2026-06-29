#!/usr/bin/env bash
# docker/verify-rehearsal.sh <beta|nightly> — post-reflow migration rehearsal gates.
set -euo pipefail

CHANNEL="${1:?usage: verify-rehearsal.sh <beta|nightly>}"
case "$CHANNEL" in
  beta|nightly) : ;;
  stable) echo "!! stable is the source; do not verify stable as a reflow target"; exit 2 ;;
  *) echo "unknown channel $CHANNEL"; exit 2 ;;
esac

cd "$(dirname "$0")/.."
SECRETS_HOME="${EZAGENT_SECRETS_HOME:-/Users/h2oslabs/Workspace/esr-ng/docker}"
SRC=stable
ENVFILE="$SECRETS_HOME/.env.${CHANNEL}"
[ -f "$ENVFILE" ] || { echo "!! missing $ENVFILE"; exit 5; }

set -a
# shellcheck disable=SC1090
. "$ENVFILE"
set +a

compose() { docker-compose --env-file "$SECRETS_HOME/.env.$1" -f docker/docker-compose.yml "${@:2}"; }
# Resolve containers by name pattern (CWD-independent; compose-from-worktree can
# misresolve project name → wrong container → wrong DB → false FATAL).
pgctr()   { docker ps -q --filter "name=ezagent-$1-postgres"; }
ezctr()   { docker ps -q --filter "name=ezagent-$1-ezagent"; }

fail() {
  echo "!! gate failed: $1" >&2
  exit 10
}

gate() {
  echo "==> gate: $1"
}

sql() {
  local channel="$1"
  local query="$2"
  local pg
  pg="$(pgctr "$channel")"
  [ -n "$pg" ] || fail "$channel postgres container missing"
  docker exec "$pg" psql -U ezagent -d "ezagent_${channel}" -At -v ON_ERROR_STOP=1 -c "$query"
}

table_count_sql() {
  local table="$1"

  if [ "$table" = sessions ]; then
    echo "SELECT count(*) FROM kind_snapshots WHERE uri LIKE 'session://%';"
  else
    echo "SELECT count(*) FROM ${table};"
  fi
}

require_count_match() {
  local label="$1"
  local query
  local src_count
  local tgt_count
  local diff
  local tolerance="${EZAGENT_REHEARSAL_ROW_TOLERANCE:-0}"

  query="$(table_count_sql "$label")"
  src_count="$(sql "$SRC" "$query")"
  tgt_count="$(sql "$CHANNEL" "$query")"
  diff=$((src_count - tgt_count))
  diff="${diff#-}"

  if [ "$diff" -gt "$tolerance" ]; then
    fail "Row-count sanity: ${label} stable=${src_count} ${CHANNEL}=${tgt_count} tolerance=${tolerance}"
  fi

  echo "    ${label}: stable=${src_count} ${CHANNEL}=${tgt_count}"
}

CTR="$(ezctr "$CHANNEL")"
[ -n "$CTR" ] || fail "$CHANNEL ezagent container missing"

gate "Migration log clean"
if docker logs "$CTR" 2>&1 | grep -Ei \
  'Ecto\.(MigrationError|QueryError|InvalidChangesetError|ConstraintError)|Postgrex\.Error|\*\* \(|migration failed|rollback failed' >/dev/null; then
  docker logs --tail=200 "$CTR" >&2
  fail "Migration log clean"
fi

gate "Row-count sanity"
for table in users entity_profiles socialware_config_objects kind_snapshots messages sessions; do
  require_count_match "$table"
done

gate "ConfigObject decode"
for key in recipe socialware; do
  count="$(
    sql "$CHANNEL" \
      "SELECT count(*) FROM socialware_config_objects WHERE key = '${key}' AND jsonb_typeof(body) = 'object';"
  )"
  if [ "$count" -lt 1 ]; then
    fail "ConfigObject decode: expected at least one decodable key=${key} row"
  fi
  echo "    ${key}: ${count} decodable rows"
done

gate "Schema version"
latest_code_version="$(
  docker exec "$CTR" sh -c \
    "ls /app/lib/ezagent_core-*/priv/repo_pg/migrations/*.exs | sed -E 's#.*/([0-9]+)_.*#\\1#' | sort -n | tail -1"
)"
target_db_version="$(sql "$CHANNEL" "SELECT max(version)::text FROM schema_migrations;")"
[ -n "$latest_code_version" ] || fail "Schema version: could not read release migrations"
[ "$target_db_version" = "$latest_code_version" ] || \
  fail "Schema version: db=${target_db_version} code=${latest_code_version}"
echo "    schema_migrations max=${target_db_version}"

gate "Agent slice integrity"
agent_uri="$(
  sql "$CHANNEL" \
    "SELECT uri FROM kind_snapshots WHERE uri LIKE 'entity://%/agent/%' ORDER BY updated_at DESC LIMIT 1;"
)"
[ -n "$agent_uri" ] || fail "Agent slice integrity: no agent kind_snapshots found"
docker exec "$CTR" /app/bin/ezagent rpc "case Ezagent.SnapshotStore.latest(\"$agent_uri\") do {:ok, %{state: s}} when is_map(s) -> :ok; other -> raise \"snapshot decode failed: #{inspect(other)}\" end"
echo "    decoded binary_to_term snapshot for ${agent_uri}"

gate "HTTP serve"
admin_port="${HOST_ADMIN_PORT:?set HOST_ADMIN_PORT in $ENVFILE}"
http_code="$(curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${admin_port}/login" || true)"
[ "$http_code" = 200 ] || fail "HTTP serve: /login returned ${http_code}"
echo "    /login returned 200"

echo "==> verify-rehearsal ok: ${CHANNEL}"
