#!/usr/bin/env bash
# CC hook → Ezagent error reporter (Phase 4-plus follow-up, 2026-05-17).
#
# Purpose: when CC's auth expires, network drops, or any local pre-flight
# fails, the CC agent itself may be unreachable — so reporting the error
# THROUGH the agent is unreliable. This hook scrapes the failure context
# and POSTs directly to Ezagent's `/api/cc-events` endpoint, bypassing the
# agent's dispatch path entirely.
#
# Configure via CC hooks (~/.claude/settings.json or per-project
# .claude/settings.json), e.g.:
#
#   {
#     "hooks": {
#       "Notification": [
#         {
#           "matcher": ".*",
#           "hooks": [
#             {
#               "type": "command",
#               "command": "/abs/path/to/cc-report-error.sh"
#             }
#           ]
#         }
#       ]
#     }
#   }
#
# Environment variables:
#   EZAGENT_URL          — base URL of the Ezagent LV server (default: http://localhost:4000)
#   EZAGENT_BRIDGE_ID    — identifier for this CC instance (default: hostname)
#
# Input: CC passes hook payload as JSON on stdin (CLAUDE_HOOK_INPUT).
# Output: silent on success; stderr on failure (non-fatal — never blocks CC).
#
# Idempotent + best-effort: a curl failure here MUST NOT take CC down.

set -u  # explicit unset = bug; missing data is fine, will fall back

EZAGENT_URL="${EZAGENT_URL:-http://localhost:4000}"
EZAGENT_BRIDGE_ID="${EZAGENT_BRIDGE_ID:-$(hostname -s 2>/dev/null || echo unknown)}"

# Read hook payload from stdin (CC convention). If absent, we still
# report a generic notification — the existence of a Notification event
# is itself signal.
payload=""
if [ ! -t 0 ]; then
  payload=$(cat 2>/dev/null || true)
fi

# Extract message text if jq is available; otherwise pass raw payload.
text=""
if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
  text=$(printf '%s' "$payload" | jq -r '.message // .text // .content // empty' 2>/dev/null || true)
fi
[ -z "$text" ] && text="$payload"
[ -z "$text" ] && text="(no message body)"

# Classify by pattern — keeps Ezagent side dumb (it doesn't need to know
# every CC error format). Add patterns here as they're observed.
level="warning"
type="notification"
case "$text" in
  *"Not logged in"*|*"Please run /login"*|*"Authentication failed"*)
    level="error"; type="auth_expired" ;;
  *"security unlock-keychain"*|*"keychain"*)
    level="error"; type="keychain_locked" ;;
  *"network"*|*"ECONNREFUSED"*|*"Connection refused"*)
    level="error"; type="network_error" ;;
  *"Rate limit"*|*"rate-limit"*)
    level="warning"; type="rate_limit" ;;
esac

# Build JSON body. Manual escaping kept tiny + jq-free for hook
# environments that don't have jq installed.
escape_json() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' '
}

body=$(printf '{"bridge_id":"%s","level":"%s","type":"%s","text":"%s"}' \
  "$(escape_json "$EZAGENT_BRIDGE_ID")" \
  "$(escape_json "$level")" \
  "$(escape_json "$type")" \
  "$(escape_json "$text")")

# Best-effort POST. Timeout aggressively so a slow Ezagent doesn't stall CC.
curl --max-time 3 --silent --show-error \
     -X POST \
     -H "Content-Type: application/json" \
     -d "$body" \
     "$EZAGENT_URL/api/cc-events" \
     >/dev/null 2>&1 || {
  echo "cc-report-error: failed to POST to $EZAGENT_URL/api/cc-events" >&2
  exit 0   # never fail the hook chain
}

exit 0
