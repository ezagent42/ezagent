#!/usr/bin/env bash
# Build the dockerized CI images (docs/superpowers/plans/2026-07-20-dockerize-ci.md,
# Task 1): the expensive deps/node_modules base (docker/Dockerfile.ci-base) is rebuilt
# ONLY when mix.lock or an asset pnpm-lock.yaml changes (lock-hash tag); the thin
# per-PR image (docker/Dockerfile.ci) is always built — it is just `COPY . .` on top
# of the cached base, so a source-only change completes in seconds.
#
# No proxy needed on this host (direct egress via clash TUN). If hex/apt/npm fetches
# fail, fall back to:
#   DOCKER_BUILD_PROXY=http://host.docker.internal:7897 docker/build-ci-image.sh
set -euo pipefail
cd "$(dirname "$0")/.."
LOCKHASH="$(cat mix.lock apps/*/assets/pnpm-lock.yaml 2>/dev/null | shasum -a 256 | cut -c1-12)"
BASE_TAG="ezagent-ci-base:${LOCKHASH}"
if ! docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
  echo "==> building CI base $BASE_TAG (deps changed)"
  DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile.ci-base \
    --build-arg HTTP_PROXY="${DOCKER_BUILD_PROXY:-}" \
    --build-arg HTTPS_PROXY="${DOCKER_BUILD_PROXY:-}" \
    -t "$BASE_TAG" -t ezagent-ci-base:latest .
else
  echo "==> CI base $BASE_TAG cached — skipping base build"
  docker tag "$BASE_TAG" ezagent-ci-base:latest
fi
echo "==> building thin CI image (source layer only)"
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile.ci --build-arg CI_BASE=ezagent-ci-base:latest -t ezagent-ci-local:latest .
