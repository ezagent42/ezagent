#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.claude/skills/kanban-off-ezagent}"

require() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if ! grep -Eq "$pattern" "$ROOT/$file"; then
    printf 'kanban-off-ezagent validation failed: %s missing %s\n' "$file" "$label" >&2
    exit 1
  fi
}

# --- per-file content gates (same grep-require style as dev-together) ---
require "commands/plan.md" "Plan completeness gate" "plan completeness gate"
require "commands/plan.md" "planned_at" "planning metadata"
require "commands/return.md" "returned_at" "return timestamp"
require "commands/return.md" "deadline_status" "return deadline status"
require "commands/push.md" "Returned-vs-stacked reconciliation" "return reconciliation"
require "commands/push.md" "duplicate|superseded|out-of-scope|late" "return exception handling"
require "commands/close.md" "PR closure|GitHub PR" "PR closure loop"
require "commands/close.md" "gh pr close|merged through GitHub|subsumed" "stale PR close guidance"
require "commands/close.md" "superpowers:finishing-a-development-branch" "finishing skill delegation"
require "commands/review.md" "planned vs\\. returned vs\\. stacked vs\\. merged" "efficiency accounting"
require "commands/review.md" "late returns" "late return reporting"
require "SKILL.md" "Board write-back" "board write-back ledger rule"
require "SKILL.md" "No empty plan" "plan ledger rule"
require "SKILL.md" "Timestamp every return" "return ledger rule"
require "SKILL.md" "Reconcile the whole ledger" "stack ledger rule"
require "SKILL.md" "Close PR state" "PR ledger rule"

# --- board check: enforce board-format.md's two layers on docs/board.md (if present) ---
BOARD="${KANBAN_OFF_BOARD:-docs/board.md}"
if [ -f "$BOARD" ]; then
  awk '
    BEGIN {
      root_seen = 0
      # the 9-stage relay chain, indexed for adjacency checks
      n = split("positioning metric pain anchor ux feature issue test pr", chain, " ")
      for (i = 1; i <= n; i++) idx[chain[i]] = i
    }
    # only "# ..." heading lines form the markmap tree; everything else is metadata
    /^#+[ \t]/ {
      d = 0
      while (substr($0, d + 1, 1) == "#") d++
      if (!root_seen) {
        if (d != 1) { print "board: first heading must be a single # root"; exit 1 }
        root_seen = 1
      } else if (d == 1) {
        print "board: more than one # root (markmap needs a single root)"; exit 1
      } else if (d > prev_depth + 1) {
        print "board: heading depth jump (e.g. # then ###) — malformed tree"; exit 1
      }
      prev_depth = d
      cur_depth = d
      has_stage[d] = 0
      next
    }
    # status field must be one of the live 4-state values
    /^>[ \t]*.*status:/ {
      if ($0 !~ /status:[ \t]*(unassigned|claimed|doing|done)/) {
        print "board: status not in {unassigned,claimed,doing,done}: " $0; exit 1
      }
    }
    # stage field: in the 9-chain, root = positioning, child = parent stage or next (相邻棒推进)
    /^>[ \t]*.*stage:/ {
      if (match($0, /stage:[ \t]*[a-z_]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/stage:[ \t]*/, "", s)
        if (!(s in idx)) { print "board: stage not in 9-chain: " s; exit 1 }
        if (cur_depth == 1 && s != "positioning") {
          print "board: root stage must be positioning, got " s; exit 1
        }
        stage_at[cur_depth] = s
        has_stage[cur_depth] = 1
        if (cur_depth > 1 && has_stage[cur_depth - 1]) {
          p = stage_at[cur_depth - 1]
          diff = idx[s] - idx[p]
          if (diff != 0 && diff != 1) {
            print "board: stage relay violation — " p " -> " s " (child must be parent stage or next stage)"; exit 1
          }
        }
      }
    }
    END {
      if (!root_seen) { print "board: no # root heading found"; exit 1 }
    }
  ' "$BOARD" || {
    printf 'kanban-off-ezagent validation failed: %s violates board-format.md\n' "$BOARD" >&2
    exit 1
  }
  printf 'kanban-off-ezagent: %s board check OK\n' "$BOARD"
else
  printf 'kanban-off-ezagent: no %s yet (run scripts/new_board.sh at product start)\n' "$BOARD"
fi

printf 'kanban-off-ezagent validation OK\n'
