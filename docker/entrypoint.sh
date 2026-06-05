#!/usr/bin/env bash
# ezagent dev/test container entrypoint: bootstrap a BLANK $EZAGENT_HOME on first boot,
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

# Static SMTP config (read-only secret) → profile credentials, if not present.
# The app auto-seeds the `smtp_config` app_setting from this file on boot, so a
# fresh/reseeded env has magic-link email working without a manual step.
if [ -f /secrets/smtp_config.json ] && [ ! -f "${PROFILE_DIR}/credentials/smtp_config.json" ]; then
  echo "[entrypoint] seeding smtp_config.json from /secrets"
  cp /secrets/smtp_config.json "${PROFILE_DIR}/credentials/smtp_config.json"
  chmod 600 "${PROFILE_DIR}/credentials/smtp_config.json"
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

# Distribution cookie: prefer EZAGENT_COOKIE (matches Ezagent.Runtime.ensure_cookie!
# + mix ezagent / bin/ezagent rpc), else fall back to a generated file cookie.
RUNTIME_DIR="${PROFILE_DIR}/runtime"
COOKIE_FILE="${RUNTIME_DIR}/cookie"
mkdir -p "${RUNTIME_DIR}"
if [ -n "${EZAGENT_COOKIE:-}" ]; then
  COOKIE="${EZAGENT_COOKIE}"
else
  if [ ! -s "${COOKIE_FILE}" ]; then
    head -c16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > "${COOKIE_FILE}"
    chmod 600 "${COOKIE_FILE}"
  fi
  COOKIE="$(cat "${COOKIE_FILE}")"
fi

# Node name MUST match Ezagent.Runtime.runtime_node() (ezagent_runtime@127.0.0.1)
# so `mix ezagent` / CLI rpc connect out-of-the-box (loopback host = local cluster).
echo "[entrypoint] starting phx.server on :${PORT:-10042} (node ezagent_runtime@127.0.0.1)"
exec elixir --name "ezagent_runtime@127.0.0.1" --cookie "${COOKIE}" -S mix phx.server
