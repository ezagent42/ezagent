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

# Blank env init. NOTE: `mix ezagent.bootstrap` includes `home.adopt_db`, which requires
# running inside the source git repo (excluded from the image) — irrelevant for a blank
# container with no repo-root DB to adopt. So we run the two steps that DO matter directly:
# home.init (skeleton) + ecto.migrate (schema). Idempotent.
if [ ! -f "${DB}" ]; then
  echo "[entrypoint] blank env at ${DB} — home.init + ecto.migrate"
  mix ezagent.home.init || true
  mix ecto.migrate
fi

# Use the SAME cookie file `Ezagent.Runtime` reads, so `mix ezagent` / `mix ezagent.e2e.run`
# (which connect via that file) match the running node's cookie.
RUNTIME_DIR="${PROFILE_DIR}/runtime"
COOKIE_FILE="${RUNTIME_DIR}/cookie"
mkdir -p "${RUNTIME_DIR}"
if [ ! -s "${COOKIE_FILE}" ]; then
  head -c16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > "${COOKIE_FILE}"
  chmod 600 "${COOKIE_FILE}"
fi
COOKIE="$(cat "${COOKIE_FILE}")"

echo "[entrypoint] starting phx.server on :${PORT:-10042} (node esr@127.0.0.1)"
exec elixir --name "esr@127.0.0.1" --cookie "${COOKIE}" -S mix phx.server
