#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/socialware-manifest-release-gate.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_pass() {
  local name="$1"
  local files="$2"

  if ! bash "$GATE" <<<"$files"; then
    fail "$name should pass"
  fi
}

expect_fail() {
  local name="$1"
  local files="$2"
  local output

  if output="$(bash "$GATE" <<<"$files" 2>&1)"; then
    fail "$name should fail"
  fi

  if ! grep -q "release.yaml" <<<"$output"; then
    fail "$name should explain that release.yaml is required"
  fi
}

expect_pass \
  "ordinary source change" \
  $'apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex'

expect_fail \
  "manifest change without release marker" \
  $'apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml'

expect_fail \
  "recipes change without release marker" \
  $'apps/ezagent_web/priv/socialware_seed/hello/recipes.yaml'

expect_pass \
  "manifest change with matching release marker" \
  $'apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml\napps/ezagent_web/priv/socialware_seed/hello/release.yaml'

expect_fail \
  "release marker for another package does not satisfy gate" \
  $'apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml\napps/ezagent_web/priv/socialware_seed/kanban/release.yaml'

echo "socialware manifest release gate tests OK"
