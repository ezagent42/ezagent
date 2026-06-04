#!/usr/bin/env bash
# ESR dev/test container entrypoint: bootstrap a BLANK $EZAGENT_HOME on first boot,
# seed the static Feishu credential from the read-only secrets mount, then run the
# Phoenix server. Per-agent OAuth creds are provisioned by the E2E harness at
# scenario time (NOT here) — this only handles the static, non-rotated Feishu cred.
set -euo pipefail

# Passthrough: `docker compose run esr <cmd>` (e.g. `mix test ...`, `mix ezagent.e2e.run ...`)
# runs that command instead of the server. No args → bootstrap + phx.server.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

PROFILE="${EZAGENT_PROFILE:-default}"
HOME_DIR="${EZAGENT_HOME:-/data}"
PROFILE_DIR="${HOME_DIR}/${PROFILE}"
DB="${PROFILE_DIR}/db/ezagent_core.db"

mkdir -p "${PROFILE_DIR}/credentials"

# Static Feishu cred (read-only secret) → profile credentials, if not already present.
if [ -f /secrets/feishu.yaml ] && [ ! -f "${PROFILE_DIR}/credentials/feishu.yaml" ]; then
  echo "[entrypoint] seeding feishu.yaml from /secrets"
  cp /secrets/feishu.yaml "${PROFILE_DIR}/credentials/feishu.yaml"
  chmod 600 "${PROFILE_DIR}/credentials/feishu.yaml"
fi

# Blank env → one-command bootstrap (home.init + adopt_db + ecto.migrate + health-check).
if [ ! -f "${DB}" ]; then
  echo "[entrypoint] blank env at ${DB} — running mix ezagent.bootstrap"
  mix ezagent.bootstrap
fi

echo "[entrypoint] starting phx.server on :${PORT:-10042}"
exec elixir --name "esr@127.0.0.1" --cookie "${EZAGENT_COOKIE:-esr_dev_cookie}" -S mix phx.server
