#!/usr/bin/env bash
# docker/smoke.sh <channel> — beta 晋级门禁:最小冒烟(随 VERIFICATION.md 扩充)
# 从 edge 网内访问该通道 ezagent(经 compose 别名 ezagent-<channel>)。
set -euo pipefail
CHANNEL="${1:?usage: smoke.sh <channel>}"
docker run --rm --network ezagent_edge curlimages/curl:latest \
  -fsS "http://ezagent-${CHANNEL}:10042/" >/dev/null && echo "smoke OK: ${CHANNEL} serving"
