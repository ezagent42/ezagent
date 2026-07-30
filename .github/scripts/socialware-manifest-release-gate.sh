#!/usr/bin/env bash
set -euo pipefail

# Reads a newline-delimited changed-file list on stdin. A socialware package that
# changes its deploy manifest or recipes must also change its release marker in
# the same PR. The marker makes the required governed import an explicit release
# action instead of something an operator has to remember after deployment.

awk '
  /^apps\/[^/]+\/priv\/socialware_seed\/[^/]+\/(manifest|recipes)\.yaml$/ {
    package_dir = $0
    sub(/\/[^/]+$/, "", package_dir)

    if (!(package_dir in packages)) {
      packages[package_dir] = 1
      package_count++
    }
  }

  NF { changed[$0] = 1 }

  END {
    if (package_count == 0) {
      print "socialware manifest release gate: no manifest or recipe changes"
      exit 0
    }

    for (package_dir in packages) {
      marker = package_dir "/release.yaml"

      if (!(marker in changed)) {
        printf "::error file=%s::socialware package changed without %s\n", package_dir, marker > "/dev/stderr"
        printf "Update %s in this PR, then release with:\n", marker > "/dev/stderr"
        printf "  mix ezagent.socialware.import_remote %s/manifest.yaml --dry-run\n", package_dir > "/dev/stderr"
        printf "  mix ezagent.socialware.import_remote %s/manifest.yaml\n", package_dir > "/dev/stderr"
        failed = 1
      }
    }

    exit failed
  }
'
