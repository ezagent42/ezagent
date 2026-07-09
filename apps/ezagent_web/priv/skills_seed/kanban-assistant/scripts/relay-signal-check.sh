#!/usr/bin/env bash
# relay-signal-check.sh — assert the kanban-team completion-marker literal is the
# ONE contract point between the collaboration protocol and the routing transport
# (spec §0.1/§4.2). The marker MUST be byte-identical in three places:
#   1. the kanban-assistant protocol module (references/kanban-team-collaboration.md)
#   2. the dev-together relay overlay (kanban-assistant-held; the dev-together
#      skill itself is owner-only and never modified)
#      (.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md)
#   3. the kanban Definition manifest (routing_rules matcher "arg" — the
#      boot-publish demo module; checked only if demo.ex is present)
# Run from the repo root. Exit non-zero on any mismatch.
set -euo pipefail

MARKER='__done__'
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"

PM_PROTO="$ROOT/.claude/skills/kanban-assistant/references/kanban-team-collaboration.md"
DEV_OVERLAY="$ROOT/.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md"
KANBAN_TEAM="$ROOT/apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/demo.ex"
MANIFEST_YAML="$ROOT/apps/ezagent_plugin_kanban/priv/socialware/kanban/manifest.yaml"

fail() { echo "relay-signal-check FAIL: $1" >&2; exit 1; }

grep -qF "$MARKER" "$PM_PROTO" || fail "marker '$MARKER' missing from $PM_PROTO"
grep -qF "$MARKER" "$DEV_OVERLAY" || fail "marker '$MARKER' missing from $DEV_OVERLAY"

# S3 side: only assert once the Definition module exists (routing_rules landed).
if [ -f "$KANBAN_TEAM" ]; then
  grep -qF "\"$MARKER\"" "$KANBAN_TEAM" \
    || fail "marker '$MARKER' missing from routing_rules in $KANBAN_TEAM (S3 contract point)"
  if [ -f "$MANIFEST_YAML" ]; then
    grep -qF "\"$MARKER\"" "$MANIFEST_YAML" \
      || fail "marker '$MARKER' missing from $MANIFEST_YAML (YAML manifest, 4th contract point)"
  fi
  echo "relay-signal-check OK: '$MARKER' aligned across pm protocol, dev overlay, Definition, and YAML manifest."
else
  echo "relay-signal-check OK: '$MARKER' aligned across pm protocol + dev overlay (Definition lands in S3)."
fi
