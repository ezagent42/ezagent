#!/usr/bin/env bash
# docker/backup.sh <channel> — 逐域逻辑备份 → ./backups/<channel>/<ts>/
# codex#12:不硬编码容器/卷名,用 compose 解析(project=ezagent-<channel>)
set -euo pipefail
CHANNEL="${1:?usage: backup.sh <channel>}"; cd "$(dirname "$0")/.."
set -a; . "docker/.env.${CHANNEL}"; set +a
CH=(docker-compose --env-file "docker/.env.${CHANNEL}" -f docker/docker-compose.yml)
TS=$(date -u +%Y%m%dT%H%M%SZ); OUT="backups/${CHANNEL}/${TS}"; mkdir -p "$OUT"

# 实际容器名/卷名由 compose 解析,不靠字符串猜(codex#12)
PG_CTR=$("${CH[@]}" ps -q postgres)
EZ_CTR=$("${CH[@]}" ps -q ezagent)
HOME_VOL=$(docker inspect "$EZ_CTR" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
RUN_IMG=$(docker inspect "$EZ_CTR" --format '{{.Image}}')
GIT_SHA=$(git rev-parse HEAD)
DB_START=$(date -u +%Y%m%dT%H%M%SZ)

# 域1: Postgres — 逻辑 dump(一致)
docker exec "$PG_CTR" pg_dump -U ezagent -d "ezagent_${CHANNEL}" | gzip > "$OUT/db.sql.gz"
DB_END=$(date -u +%Y%m%dT%H%M%SZ)

# 域2: Agent FS — 精选快照(跳过 node_modules / _build / deps)
docker run --rm -v "${HOME_VOL}:/src:ro" -v "$PWD/$OUT:/dst" alpine \
  tar czf /dst/fs-snapshot.tar.gz \
    --exclude='*/node_modules' --exclude='*/_build' --exclude='*/deps' -C /src .

# manifest:真实可恢复锚点(codex#13)。非原子快照(无 quiesce/LSN)明确标注。
cat > "$OUT/manifest.json" <<JSON
{"channel":"${CHANNEL}","ts":"${TS}","git_sha":"${GIT_SHA}","running_image":"${RUN_IMG}",
 "image_tag":"${EZAGENT_IMAGE}","home_volume":"${HOME_VOL}","pg_dump_start":"${DB_START}",
 "pg_dump_end":"${DB_END}","db":"db.sql.gz","fs":"fs-snapshot.tar.gz","atomic":false,
 "note":"per-domain logical backup; DB and FS NOT a single consistent snapshot"}
JSON
echo "backup done: $OUT"
