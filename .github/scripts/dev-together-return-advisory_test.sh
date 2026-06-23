#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/dev-together-return-advisory.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_case() {
  local name="$1"
  local labels="$2"
  local body="$3"
  local files="$4"

  LABELS_JSON="$labels" PR_BODY="$body" "$CHECKER" <<<"$files"
}

output="$(
  run_case \
    "has return file" \
    "[]" \
    "" \
    $'lib/example.ex\ndocs/together/2026-06-23/returns/example.md'
)"

if grep -q "::warning" <<<"$output"; then
  fail "return-file case should not warn"
fi

output="$(
  run_case \
    "missing return file" \
    "[]" \
    "" \
    $'lib/example.ex\ntest/example_test.exs'
)"

if ! grep -q "::warning" <<<"$output"; then
  fail "missing-return case should warn"
fi

output="$(
  run_case \
    "skip by label" \
    '["no-dev-together-return"]' \
    "" \
    $'lib/example.ex'
)"

if grep -q "::warning" <<<"$output"; then
  fail "skip-label case should not warn"
fi

output="$(
  run_case \
    "skip by body marker" \
    "[]" \
    "Dev-Together: out-of-scope" \
    $'lib/example.ex'
)"

if grep -q "::warning" <<<"$output"; then
  fail "skip-body-marker case should not warn"
fi

echo "dev-together return advisory tests OK"
