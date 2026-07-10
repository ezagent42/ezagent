#!/usr/bin/env bash
# relay-signal-check.sh — assert the kanban-team completion-marker literal is the
# ONE contract point between the collaboration protocol and the routing transport
# (spec §0.1/§4.2). The marker MUST be byte-identical in three places:
#   1. the kanban-assistant protocol module (references/kanban-team-collaboration.md)
#   2. the dev-together relay overlay (kanban-assistant-held; the dev-together
#      skill itself is owner-only and never modified)
#      (.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md)
#   3. the shipped kanban manifest YAML (routing_rules matcher "arg" — the
#      deploy-seed package, the config one-source-of-truth; Decision #156:
#      socialware carries zero code, so there is no plugin module to check.
#      Asserted only when the repo tree is present — a deployed skill copy runs
#      outside the ezagent repo and locks the skill side only; the manifest side
#      is then locked by kanban_manifest_test.exs in repo CI.)
# Run from the repo root. Exit non-zero on any mismatch.
set -euo pipefail

MARKER='__done__'
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"

PM_PROTO="$ROOT/.claude/skills/kanban-assistant/references/kanban-team-collaboration.md"
DEV_OVERLAY="$ROOT/.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md"
MANIFEST_YAML="$ROOT/apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml"

fail() { echo "relay-signal-check FAIL: $1" >&2; exit 1; }

grep -qF "$MARKER" "$PM_PROTO" || fail "marker '$MARKER' missing from $PM_PROTO"
grep -qF "$MARKER" "$DEV_OVERLAY" || fail "marker '$MARKER' missing from $DEV_OVERLAY"

# Manifest side: only assert when the ezagent repo tree is present (deployed
# skill copies run outside it; kanban_manifest_test.exs locks that side in CI).
if [ -f "$MANIFEST_YAML" ]; then
  grep -qF "\"$MARKER\"" "$MANIFEST_YAML" \
    || fail "marker '$MARKER' missing from routing_rules in $MANIFEST_YAML (spec §4.2 contract point)"
  echo "relay-signal-check OK: '$MARKER' aligned across pm protocol, dev overlay, and the shipped manifest YAML."
else
  echo "relay-signal-check OK: '$MARKER' aligned across pm protocol + dev overlay (manifest YAML not in this tree; locked by kanban_manifest_test.exs in repo CI)."
fi
