#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.claude/skills/dev-together}"

require() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if ! grep -Eq "$pattern" "$ROOT/$file"; then
    printf 'dev-together validation failed: %s missing %s\n' "$file" "$label" >&2
    exit 1
  fi
}

require "commands/plan.md" "Plan completeness gate" "plan completeness gate"
require "commands/plan.md" "planned_at|owner|lead|dev" "planning metadata"
require "commands/return.md" "returned_at" "return timestamp"
require "commands/return.md" "deadline_status" "return deadline status"
require "commands/push.md" "Returned-vs-stacked reconciliation" "return reconciliation"
require "commands/push.md" "duplicate|superseded|out-of-scope|late" "return exception handling"
require "commands/close.md" "PR closure|GitHub PR" "PR closure loop"
require "commands/close.md" "gh pr close|merged through GitHub|subsumed" "stale PR close guidance"
require "commands/close.md" "superpowers:finishing-a-development-branch" "finishing skill delegation"
require "commands/review.md" "planned vs\\. returned vs\\. stacked vs\\. merged" "efficiency accounting"
require "commands/review.md" "late returns" "late return reporting"
require "SKILL.md" "No empty plan" "plan ledger rule"
require "SKILL.md" "Timestamp every return" "return ledger rule"
require "SKILL.md" "Reconcile the whole ledger" "stack ledger rule"
require "SKILL.md" "Close PR state" "PR ledger rule"
require "SKILL.md" "\\.superpowers/sdd/" "Superpowers v6.0.3 SDD scratch rule"

if ! git check-ignore -q .superpowers/sdd; then
  printf 'dev-together validation failed: .superpowers/sdd is not git-ignored\n' >&2
  exit 1
fi

if find "$ROOT" -name '*.md' -type f -print0 | xargs -0 grep -n "\.git/sdd" >/dev/null; then
  printf 'dev-together validation failed: stale .git/sdd reference found\n' >&2
  exit 1
fi

printf 'dev-together validation OK\n'
