#!/usr/bin/env bash
set -euo pipefail

# Reads a newline-delimited changed-file list on stdin. A socialware package that
# changes its deploy manifest or recipes must also change its release marker in
# the same PR. The marker makes the required governed import an explicit release
# action instead of something an operator has to remember after deployment.

declare -A changed=()
declare -A packages=()

while IFS= read -r path; do
  [ -n "$path" ] || continue
  changed["$path"]=1

  if [[ "$path" =~ ^apps/[^/]+/priv/socialware_seed/([^/]+)/(manifest\.yaml|recipes\.yaml)$ ]]; then
    packages["${path%/*}"]=1
  fi
done

if [ "${#packages[@]}" -eq 0 ]; then
  echo "socialware manifest release gate: no manifest or recipe changes"
  exit 0
fi

failed=0

for package_dir in "${!packages[@]}"; do
  marker="$package_dir/release.yaml"

  if [ -z "${changed[$marker]+x}" ]; then
    echo "::error file=$package_dir::socialware package changed without $marker" >&2
    echo "Update $marker in this PR, then release with:" >&2
    echo "  mix ezagent.socialware.import_remote $package_dir/manifest.yaml --dry-run" >&2
    echo "  mix ezagent.socialware.import_remote $package_dir/manifest.yaml" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "socialware manifest release gate: release marker present for changed package(s)"
