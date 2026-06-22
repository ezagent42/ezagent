#!/usr/bin/env bash
# dev-together — scaffold today's working folder under docs/together/.
# Run from the repo root. Usage: scripts/new_day.sh [YYYY-MM-DD]
set -euo pipefail

DATE="${1:-$(date +%F)}"
ROOT="${DEV_TOGETHER_ROOT:-docs/together}"
DIR="$ROOT/$DATE"

mkdir -p "$DIR/handoffs" "$DIR/returns"
[ -f "$DIR/plan.md" ]  || printf '# dev-together plan — %s\n\n_tasks · scope · owned surfaces/files · per-task branch · cross-task conflict map · handoff order_\n' "$DATE" > "$DIR/plan.md"
[ -f "$DIR/stack.md" ] || printf '# dev-together merge stack — %s\n\n_returned handoffs in analyzed merge order · dependencies · conflict check · per-entry status_\n' "$DATE" > "$DIR/stack.md"

echo "dev-together: $DIR ready (handoffs/ returns/ plan.md stack.md)"
