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
mkdir -p "$(dirname "${DATABASE_PATH}")" "${PROFILE_DIR}/credentials" "${PROFILE_DIR}/runtime"

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
