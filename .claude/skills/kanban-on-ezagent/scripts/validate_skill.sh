#!/usr/bin/env bash
set -euo pipefail

# Validate the kanban-on-ezagent skill: the same grep-require discipline as the
# off twin, plus on-specific gates proving every board-touch goes through dispatch
# (not a file edit) and the off↔on parity is asserted.

ROOT="${1:-.claude/skills/kanban-on-ezagent}"

require() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if ! grep -Eq "$pattern" "$ROOT/$file"; then
    printf 'kanban-on-ezagent validation failed: %s missing %s\n' "$file" "$label" >&2
    exit 1
  fi
}

# --- twin disambiguation: the description must point at the off twin ---
require "SKILL.md" "kanban-off-ezagent" "off-twin disambiguation"
require "SKILL.md" "resource://" "live board URI"
require "SKILL.md" "dispatch" "dispatch medium"
require "SKILL.md" "snapshot" "snapshot persistence"

# --- ledger rules (same five as off) ---
require "SKILL.md" "No empty plan" "plan ledger rule"
require "SKILL.md" "Timestamp every return" "return ledger rule"
require "SKILL.md" "Reconcile the whole ledger" "stack ledger rule"
require "SKILL.md" "Close PR state" "PR ledger rule"
require "SKILL.md" "Board write-back" "board write-back ledger rule"

# --- on-specific: every mutating command must touch the board BY DISPATCH ---
require "commands/init.md" "get_tree" "init read-by-dispatch"
require "commands/plan.md" "Plan completeness gate" "plan completeness gate"
require "commands/plan.md" "planned_at" "planning metadata"
require "commands/plan.md" "get_tree" "plan reads by dispatch"
require "commands/handoff.md" "add_node" "handoff relays by dispatch"
require "commands/dive.md" "claim_node" "dive claims by dispatch"
require "commands/dive.md" "set_status" "dive sets status by dispatch"
require "commands/return.md" "returned_at" "return timestamp"
require "commands/return.md" "deadline_status" "return deadline status"
require "commands/return.md" "attach_artifact|set_status|set_metric" "return writes by dispatch"
require "commands/push.md" "Returned-vs-stacked reconciliation" "return reconciliation"
require "commands/push.md" "duplicate|superseded|out-of-scope|late" "return exception handling"
require "commands/close.md" "PR closure|GitHub PR" "PR closure loop"
require "commands/close.md" "gh pr close|merged through GitHub|subsumed" "stale PR close guidance"
require "commands/close.md" "superpowers:finishing-a-development-branch" "finishing skill delegation"
require "commands/close.md" "set_status|set_stage|sync_github" "close advances by dispatch"
require "commands/review.md" "planned vs\\. returned vs\\. stacked vs\\. merged" "efficiency accounting"
require "commands/review.md" "late returns" "late return reporting"
require "commands/review.md" "get_tree" "review reconciles by dispatch"

# --- references present + grounded ---
require "references/live-board-access.md" "Invocation.dispatch" "dispatch envelope grounding"
require "references/live-board-access.md" "with_action" "target URI grounding"
require "references/live-board-access.md" "kanban.ex:" "kanban Behavior file:line grounding"
require "references/off-on-parity.md" "kanban-off-ezagent" "off twin reference"
require "references/agent-orchestration.md" "kanban-manager" "agent orchestration entry"
require "references/agent-orchestration.md" "待编排 grounding 补全" "orchestration placeholder marker"

# --- on board is created BY DISPATCH (auto-spawn), not a file scaffold:
#     init must assert the auto-spawn path, and no scripts/new_board.sh may exist. ---
require "commands/init.md" "auto-spawn" "init creates board by dispatch (auto-spawn)"
if [ -f "$ROOT/scripts/new_board.sh" ]; then
  printf 'kanban-on-ezagent validation failed: scripts/new_board.sh exists (on board is a live Kind, created by dispatch — no file scaffold)\n' >&2
  exit 1
fi

printf 'kanban-on-ezagent validation OK\n'
