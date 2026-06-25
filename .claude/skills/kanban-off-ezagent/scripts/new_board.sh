#!/usr/bin/env bash
# kanban-off-ezagent — scaffold the ONE durable docs/board.md (once, at product
# start) + today's docs/together/<date>/ working folder.
# Run from the repo root. Usage: scripts/new_board.sh [产品名] [YYYY-MM-DD]
# Idempotent: an existing board.md is never overwritten.
set -euo pipefail

PRODUCT="${1:-<产品名>}"
DATE="${2:-$(date +%F)}"

BOARD="${KANBAN_OFF_BOARD:-docs/board.md}"
ROOT="${KANBAN_OFF_ROOT:-docs/together}"
DIR="$ROOT/$DATE"

# 1. The one durable board — scaffold once, never clobber.
mkdir -p "$(dirname "$BOARD")"
if [ ! -f "$BOARD" ]; then
  cat > "$BOARD" <<BOARD_EOF
# $PRODUCT
> stage: positioning · owner: — · status: unassigned
BOARD_EOF
  echo "kanban-off-ezagent: scaffolded $BOARD (positioning root)"
else
  echo "kanban-off-ezagent: $BOARD already exists — left untouched"
fi

# 2. Today's working folder (the per-day cadence log; the board persists).
mkdir -p "$DIR/handoffs" "$DIR/returns"
if [ ! -f "$DIR/plan.md" ]; then
  cat > "$DIR/plan.md" <<PLAN
# kanban-off-ezagent plan — $DATE

> **planned_at:** YYYY-MM-DD HH:MM +TZ
> **lead:** <name>
> **day_deadline:** YYYY-MM-DD HH:MM +TZ
> **timezone:** <timezone>

_a coordination snapshot of docs/board.md — NOT central assignment_

## Active nodes (claimed · status: doing — multi-day continuity)

| Board node | Owner | Stage | What advances today |
|---|---|---|---|
| <node id/title> | <name> | <stage> | <today's increment> |

## Ready nodes (open for claim — relay-able next stages)

| Board node | Stage | Open for claim |
|---|---|---|
| <node id/title> | <stage> | yes |

## Conflict Map

| Shared surface/file | Nodes | Serialization owner | Parallel/serialized |
|---|---|---|---|
| <path/surface> | <nodes> | <owner> | <rule> |
PLAN
fi

if [ ! -f "$DIR/stack.md" ]; then
  cat > "$DIR/stack.md" <<STACK
# kanban-off-ezagent merge stack — $DATE

_returned nodes in analyzed merge order · dependencies · conflict check · status_

## Returned-vs-stacked reconciliation

| Return file | Board node | returned_at | deadline_status | Stack status | Notes |
|---|---|---|---|---|---|
| <returns/task.md> | <node id> | <time> | <on_time/late/deferred/out_of_scope> | <stacked/superseded/late/out-of-scope/blocked> | <reason> |

## Merge Order

1. <node> — <branch> — <ready/needs-rebase/blocked>
STACK
fi

echo "kanban-off-ezagent: $DIR ready (handoffs/ returns/ plan.md stack.md)"
