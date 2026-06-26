#!/usr/bin/env bash
# docker/deploy.sh <channel> — build-once/promote-artifact 部署 + 健康检查 + 回滚
# codex 致命#1/#2:infra 独立生命周期(自带 .env.infra),channel 只用自己的 compose,
#   经 external ezagent_edge 连通。绝不把 infra 文件混进 channel 命令(否则合成单 project + 缺 infra env)。
set -euo pipefail
CHANNEL="${1:?usage: deploy.sh <nightly|beta|stable>}"
cd "$(dirname "$0")/.."
case "$CHANNEL" in nightly|beta|stable) : ;; *) echo "unknown channel $CHANNEL"; exit 2 ;; esac

# secrets 持久家(main checkout),与 ephemeral checkout(runner _work)解耦:
#   code(compose/脚本/mihomo/caddy)来自当前 checkout;secrets(.env.*)从这个绝对路径读。
SECRETS_HOME="${EZAGENT_SECRETS_HOME:-/Users/h2oslabs/Workspace/esr-ng/docker}"
ENVFILE="$SECRETS_HOME/.env.${CHANNEL}"
[ -f "$ENVFILE" ] || { echo "!! 缺 $ENVFILE(secrets 持久家;设 EZAGENT_SECRETS_HOME 覆盖)"; exit 5; }

# channel compose:project 名来自 compose 里的 name: ezagent-${CHANNEL};stable 加 cloudflared profile
CH=(docker-compose --env-file "$ENVFILE" -f docker/docker-compose.yml)
[ "$CHANNEL" = stable ] && CH+=(--profile stable)
# 容器 id 由 compose 解析(不假设 hyphen/underscore 命名格式;docker-compose v5 兼容)

# 确保共享 infra(tailscale+mihomo+caddy)在跑 —— 独立 project + 独立 env(codex#1/#2)
docker-compose --env-file "$SECRETS_HOME/.env.infra" -f docker/docker-compose.infra.yml up -d

# 部署 SHA = 当前 checkout HEAD(checkout@v4 已把对应 ref 放 HEAD;不用 origin/<ref>,advisor)
SHA=$(git rev-parse --short HEAD)
SHA_IMG="ezagent:${SHA}"; CHAN_IMG="ezagent:${CHANNEL}"
PREV=$(docker image inspect "$CHAN_IMG" --format '{{.Id}}' 2>/dev/null || echo none)
echo "==> $CHANNEL @ $SHA"

# build-once:仅 nightly 允许构建;beta/stable 必须晋级已存在的 nightly 制品(codex 致命#3,fail-closed)
if ! docker image inspect "$SHA_IMG" >/dev/null 2>&1; then
  if [ "$CHANNEL" = nightly ]; then
    echo "==> building $SHA_IMG"; EZAGENT_IMAGE="$SHA_IMG" "${CH[@]}" build ezagent
  else
    echo "!! $SHA_IMG 不存在 — beta/stable 只晋级已构建制品,拒绝重编"; exit 3
  fi
fi
docker tag "$SHA_IMG" "$CHAN_IMG"
TARGET_ID=$(docker image inspect "$CHAN_IMG" --format '{{.Id}}')

# 起 postgres(幂等),再 force-recreate ezagent 让它真正换到新镜像(codex 致命#4)
EZAGENT_IMAGE="$CHAN_IMG" "${CH[@]}" up -d --no-build
EZAGENT_IMAGE="$CHAN_IMG" "${CH[@]}" up -d --no-build --force-recreate --no-deps ezagent
CTR=$(EZAGENT_IMAGE="$CHAN_IMG" "${CH[@]}" ps -q ezagent)
RUN_ID=$(docker inspect --format '{{.Image}}' "$CTR")
[ "$RUN_ID" = "$TARGET_ID" ] || { echo "!! 运行容器 image($RUN_ID) != 目标($TARGET_ID)"; exit 4; }

# 健康检查:直接读容器 health(codex#5,不靠 compose ps json)
echo "==> health check"; ok=0
for _ in $(seq 1 30); do
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$CTR" 2>/dev/null)" = healthy ] && { ok=1; break; }
  sleep 5
done
if [ "$ok" != 1 ]; then
  echo "!! health failed"
  if [ "$PREV" != none ]; then
    echo "==> rollback → $PREV"; docker tag "$PREV" "$CHAN_IMG"
    EZAGENT_IMAGE="$CHAN_IMG" "${CH[@]}" up -d --no-build --force-recreate --no-deps ezagent
  else
    echo "!! 首部署无可回滚镜像 — 保留失败态,需人工介入"
  fi
  exit 1
fi
echo "==> $CHANNEL healthy on $CHAN_IMG ($TARGET_ID)"
