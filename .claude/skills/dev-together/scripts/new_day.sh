#!/usr/bin/env bash
# dev-together — scaffold today's working folder under docs/together/.
# Run from the repo root. Usage: scripts/new_day.sh [YYYY-MM-DD]
set -euo pipefail

DATE="${1:-$(date +%F)}"
ROOT="${DEV_TOGETHER_ROOT:-docs/together}"
DIR="$ROOT/$DATE"

mkdir -p "$DIR/handoffs" "$DIR/returns"
if [ ! -f "$DIR/plan.md" ]; then
  cat > "$DIR/plan.md" <<PLAN
# dev-together plan — $DATE

> **planned_at:** YYYY-MM-DD HH:MM +TZ
> **lead:** <name>
> **day_deadline:** YYYY-MM-DD HH:MM +TZ
> **timezone:** <timezone>

## Tasks

| Task | Owner/dev | Branch | Scope | Owned surfaces/files | Required reading | DoD artifact | Deadline |
|---|---|---|---|---|---|---|---|
| <task-id> | <name> | \`<branch>\` | <tight scope> | <paths/surfaces> | <docs/skills> | <screenshot/transcript/e2e> | <time> |

## Conflict Map

| Shared surface/file | Tasks | Serialization owner | Resolution |
|---|---|---|---|
| <path/surface> | <tasks> | <owner> | <parallel/serialized/rebase rule> |

## Handoff Order

1. <task-id> — <why this order>

## Discuss-First / Brainstorming

- <task-id> — <why design confirmation is or is not required>
PLAN
fi

if [ ! -f "$DIR/stack.md" ]; then
  cat > "$DIR/stack.md" <<STACK
# dev-together merge stack — $DATE

_returned handoffs in analyzed merge order · dependencies · conflict check · per-entry status_

## Returned-vs-stacked reconciliation

| Return file | Task | returned_at | deadline_status | Stack status | Notes |
|---|---|---|---|---|---|
| <returns/task.md> | <task> | <time> | <on_time/late/deferred/out_of_scope> | <stacked/superseded/blocked> | <reason> |

## Merge Order

1. <task> — <branch> — <ready/needs-rebase/blocked>
STACK
fi

echo "dev-together: $DIR ready (handoffs/ returns/ plan.md stack.md)"
