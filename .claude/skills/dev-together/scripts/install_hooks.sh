#!/usr/bin/env bash
# dev-together init — install the handoff-deadline reminder hook into a
# developer's agent environment (drops the hook script into <target>/hooks/ and
# wires a Stop hook in <target>/settings.json). Idempotent; prints what it changed.
#
#   scripts/install_hooks.sh [--deadline HH:MM] [--target <.claude dir>]
#
# Defaults: --deadline 20:00 ; --target = the project's .claude (if in a git repo) else ~/.claude
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEADLINE="20:00"
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --deadline) DEADLINE="${2:?}"; shift 2;;
    --target)   TARGET="${2:?}"; shift 2;;
    -h|--help)  echo "usage: install_hooks.sh [--deadline HH:MM] [--target <.claude dir>]"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [ -z "$TARGET" ]; then
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    TARGET="$(git rev-parse --show-toplevel)/.claude"
  else
    TARGET="$HOME/.claude"
  fi
fi

mkdir -p "$TARGET/hooks"
cp "$SKILL_DIR/hooks/handoff-deadline-reminder.sh" "$TARGET/hooks/handoff-deadline-reminder.sh"
chmod +x "$TARGET/hooks/handoff-deadline-reminder.sh"
echo "✓ hook       → $TARGET/hooks/handoff-deadline-reminder.sh"

printf 'deadline=%s\n' "$DEADLINE" > "$TARGET/dev-together.conf"
echo "✓ deadline   → $TARGET/dev-together.conf (deadline=$DEADLINE)"

SETTINGS="$TARGET/settings.json"
# The command STRING baked into settings.json must be PORTABLE: settings.json is
# committed and shared across machines, so a baked absolute path (e.g.
# /home/<user>/.../.claude/...) breaks every other checkout's Stop hook. When the
# target is the repo's own .claude, emit the literal ${CLAUDE_PROJECT_DIR} token
# (Claude Code expands it per-machine at runtime). Only fall back to an absolute
# path for a non-repo target (e.g. ~/.claude), whose settings.json isn't committed.
if git rev-parse --show-toplevel >/dev/null 2>&1 && [ "$TARGET" = "$(git rev-parse --show-toplevel)/.claude" ]; then
  CMD_BASE='${CLAUDE_PROJECT_DIR}/.claude'
else
  CMD_BASE="$TARGET"
fi
HOOK_CMD="DEV_TOGETHER_CONF=$CMD_BASE/dev-together.conf $CMD_BASE/hooks/handoff-deadline-reminder.sh"
if command -v jq >/dev/null 2>&1; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp="$(mktemp)"
  jq --arg cmd "$HOOK_CMD" '
    .hooks //= {} | .hooks.Stop //= [] |
    if ([.hooks.Stop[]?.hooks[]?.command // ""] | any(test("handoff-deadline-reminder")))
    then .
    else .hooks.Stop += [{"hooks":[{"type":"command","command":$cmd}]}]
    end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "✓ Stop hook  → $SETTINGS"
else
  cat <<EOF
! jq not found — add this Stop hook to $SETTINGS by hand:
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "$HOOK_CMD" } ] } ] }
EOF
fi
echo "dev-together: installed. Reminder fires within ${DEV_TOGETHER_WARN_MIN:-90}min of $DEADLINE. Change later: re-run with --deadline, or edit $TARGET/dev-together.conf."
