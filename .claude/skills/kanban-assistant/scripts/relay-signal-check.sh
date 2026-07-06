#!/usr/bin/env bash
# relay-signal-check.sh — assert the kanban-team completion-marker literal is the
# ONE contract point between the collaboration protocol and the routing transport
# (spec §0.1/§4.2). The marker MUST be byte-identical in three places:
#   1. the kanban-assistant protocol module (references/kanban-team-collaboration.md)
#   2. the dev-together overlay  (.claude/skills/dev-together/references/kanban-team-relay.md)
#   3. the kanban-team Definition (routing_rules matcher "arg" — lands in S3;
#      checked only if kanban_team.ex is present)
# Run from the repo root. Exit non-zero on any mismatch.
set -euo pipefail

MARKER='__done__'
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"

PM_PROTO="$ROOT/.claude/skills/kanban-assistant/references/kanban-team-collaboration.md"
DEV_OVERLAY="$ROOT/.claude/skills/dev-together/references/kanban-team-relay.md"
KANBAN_TEAM="$ROOT/apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex"

fail() { echo "relay-signal-check FAIL: $1" >&2; exit 1; }

grep -qF "$MARKER" "$PM_PROTO" || fail "marker '$MARKER' missing from $PM_PROTO"
grep -qF "$MARKER" "$DEV_OVERLAY" || fail "marker '$MARKER' missing from $DEV_OVERLAY"

# S3 side: only assert once the Definition module exists (routing_rules landed).
if [ -f "$KANBAN_TEAM" ]; then
  grep -qF "\"$MARKER\"" "$KANBAN_TEAM" \
    || fail "marker '$MARKER' missing from routing_rules in $KANBAN_TEAM (S3 contract point)"
  echo "relay-signal-check OK: '$MARKER' aligned across pm protocol, dev overlay, and Definition."
else
  echo "relay-signal-check OK: '$MARKER' aligned across pm protocol + dev overlay (Definition lands in S3)."
fi
