#!/usr/bin/env bash
# ESR PROD entrypoint: run migrations via the release's `eval`, then start the
# release in the foreground. Prod data lives in the bind-mounted stable home
# (EZAGENT_HOME=/data → ~/.ezagent on the host), so creds (incl. the prod
# feishu app) are already present — NOT seeded here.
set -euo pipefail

# Passthrough: `docker compose run esr <cmd>` (e.g. `bin/ezagent eval ...`,
# `bin/ezagent remote`) runs that instead of the server.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

PROFILE="${EZAGENT_PROFILE:-default}"
HOME_DIR="${EZAGENT_HOME:-/data}"
PROFILE_DIR="${HOME_DIR}/${PROFILE}"

export DATABASE_PATH="${DATABASE_PATH:-${PROFILE_DIR}/db/ezagent_core.db}"

# Home skeleton (release has no `mix ezagent.home.init`). Mirror
# Ezagent.Home.skeleton_dirs (credentials/db/snapshots/logs/plugins) + runtime,
# so a CLEAN bind-mounted home (prod starts blank) has the dirs the BEAM needs.
chmod 700 "${PROFILE_DIR}" 2>/dev/null || true
for d in credentials db snapshots logs plugins runtime; do
  mkdir -p "${PROFILE_DIR}/${d}"
done
chmod 700 "${PROFILE_DIR}/credentials" 2>/dev/null || true

# Seed the static prod Feishu credential from the read-only secrets mount on
# first boot (the container OWNS the bind dir it just created). Thereafter it
# persists in the prod home. Per-agent OAuth is provisioned later, not here.
if [ -f /secrets/feishu.yaml ] && [ ! -f "${PROFILE_DIR}/credentials/feishu.yaml" ]; then
  echo "[entrypoint.prod] seeding feishu.yaml from /secrets"
  cp /secrets/feishu.yaml "${PROFILE_DIR}/credentials/feishu.yaml"
  chmod 600 "${PROFILE_DIR}/credentials/feishu.yaml"
fi

# SECRET_KEY_BASE is REQUIRED by config/runtime.exs (it raises if missing).
# If the operator didn't supply one via env, bootstrap + persist one in the
# stable prod home (same pattern as the dev cookie) so restarts are stable.
if [ -z "${SECRET_KEY_BASE:-}" ]; then
  SKB_FILE="${PROFILE_DIR}/runtime/secret_key_base"
  if [ ! -s "${SKB_FILE}" ]; then
    head -c48 /dev/urandom | base64 | tr -d '\n' > "${SKB_FILE}"
    chmod 600 "${SKB_FILE}"
  fi
  export SECRET_KEY_BASE="$(cat "${SKB_FILE}")"
fi

echo "[entrypoint.prod] migrating (DATABASE_PATH=${DATABASE_PATH})"
/app/bin/ezagent eval "EzagentCore.Release.migrate()"

echo "[entrypoint.prod] starting release on :${PORT:-10042} (public: ${EZAGENT_PUBLIC_HOST:-app.ezagent.chat})"
exec /app/bin/ezagent start
