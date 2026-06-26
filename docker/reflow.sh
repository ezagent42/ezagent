#!/usr/bin/env bash
# docker/reflow.sh <beta|nightly> — 把 stable(生产)数据**单向**回流到低环境,用于测试迁移。
#
# 流程:保住目标环境自己的 credentials → 用 stable 全量数据覆盖目标(DB + agent-FS)→
#       目标(更新的)代码跑 Release.migrate()(=测试迁移)→ 把目标的 credentials 盖回去
#       (prod 真实凭据**永不落到低环境**)。
#
# ⚠️ 单向:source 永远是 stable,target 只能是 beta/nightly。脚本**绝不写 stable**。
set -euo pipefail
TARGET="${1:?usage: reflow.sh <beta|nightly>(source 固定 stable)}"
case "$TARGET" in
  beta|nightly) : ;;
  stable) echo "!! 拒绝:stable 只能作 source,不能作 target(单向回流)"; exit 2 ;;
  *) echo "unknown target $TARGET"; exit 2 ;;
esac
cd "$(dirname "$0")/.."
SECRETS_HOME="${EZAGENT_SECRETS_HOME:-/Users/h2oslabs/Workspace/esr-ng/docker}"
SRC=stable

# 敏感表(回流后用目标环境的覆盖)。可用 EZAGENT_CRED_TABLES 覆盖。
CRED_TABLES="${EZAGENT_CRED_TABLES:-credential_grants entity_tokens protocol_api_keys magic_link_tokens user_default_credential_sources workspace_shared_credential_sources email_inbound_binding external_mirror_bindings feishu_user_bindings socialware_anon_bindings invite_codes}"
# agent-FS 里的凭据子树(同样用目标环境的覆盖)
CRED_FS_PATH="${EZAGENT_CRED_FS_PATH:-default/credentials}"

compose() { docker-compose --env-file "$SECRETS_HOME/.env.$1" -f docker/docker-compose.yml "${@:2}"; }
pgctr()   { compose "$1" ps -q postgres; }
ezctr()   { compose "$1" ps -q ezagent; }
homevol() { docker inspect "$(ezctr "$1")" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}'; }

SRC_PG=$(pgctr "$SRC"); TGT_PG=$(pgctr "$TARGET")
[ -n "$SRC_PG" ] && [ -n "$TGT_PG" ] || { echo "!! stable/$TARGET stack 未在跑"; exit 3; }
TGT_VOL=$(homevol "$TARGET"); SRC_VOL=$(homevol "$SRC")
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "==> reflow $SRC → $TARGET (work=$WORK)"

# ---- 1. 保住目标环境自己的 credentials(DB data-only + FS 子树)----
echo "==> [1/6] 保存 $TARGET 现有 credentials"
TBL_ARGS=(); for t in $CRED_TABLES; do TBL_ARGS+=(-t "$t"); done
docker exec "$TGT_PG" pg_dump -U ezagent -d "ezagent_${TARGET}" --data-only --disable-triggers "${TBL_ARGS[@]}" > "$WORK/tgt-creds.sql"
docker run --rm -v "${TGT_VOL}:/src:ro" -v "$WORK:/out" alpine \
  sh -c "tar czf /out/tgt-credfs.tar -C /src '$CRED_FS_PATH' 2>/dev/null || echo 'no $CRED_FS_PATH in target (ok)'"

# ---- 2. 停目标 ezagent(避免回流时写)----
echo "==> [2/6] 停 $TARGET ezagent"
compose "$TARGET" stop ezagent >/dev/null

# ---- 3. 回流 DB:stable 全量 → 覆盖 target ----
echo "==> [3/6] 回流 DB(stable 全量 → $TARGET)"
docker exec "$SRC_PG" pg_dump -U ezagent -d "ezagent_${SRC}" > "$WORK/src-full.sql"
docker exec -i "$TGT_PG" psql -U ezagent -d "ezagent_${TARGET}" -v ON_ERROR_STOP=1 \
  -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' >/dev/null
docker exec -i "$TGT_PG" psql -U ezagent -d "ezagent_${TARGET}" -q < "$WORK/src-full.sql" >/dev/null

# ---- 4. 回流 agent-FS:stable *_home → target *_home,然后盖回 target 的 credentials 子树 ----
echo "==> [4/6] 回流 agent-FS + 盖回 $TARGET credentials 子树"
docker run --rm -v "${SRC_VOL}:/src:ro" -v "${TGT_VOL}:/dst" alpine \
  sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; cp -a /src/. /dst/'
docker run --rm -v "${TGT_VOL}:/dst" -v "$WORK:/in" alpine \
  sh -c "if [ -f /in/tgt-credfs.tar ]; then rm -rf \"/dst/$CRED_FS_PATH\"; tar xzf /in/tgt-credfs.tar -C /dst; echo restored-fs-creds; fi"

# ---- 5. 起目标 ezagent → 跑 Release.migrate()(= 测试迁移 against prod 数据)----
echo "==> [5/6] 起 $TARGET ezagent → 迁移"
EZAGENT_IMAGE="ezagent:${TARGET}" compose "$TARGET" up -d --no-build --force-recreate --no-deps ezagent >/dev/null
CTR=$(ezctr "$TARGET")
ok=0; for _ in $(seq 1 30); do
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$CTR" 2>/dev/null)" = healthy ] && { ok=1; break; }; sleep 5
done
[ "$ok" = 1 ] || { echo "!! $TARGET 迁移后未 healthy — 暂停,人工查 docker logs $CTR"; exit 4; }

# ---- 6. 盖回目标 DB credentials(迁移后 schema 已对齐;replica role 绕 FK)----
echo "==> [6/6] 盖回 $TARGET DB credentials(prod 凭据被替换)"
{
  # replica role 关 FK 触发 → 用 DELETE(非 TRUNCATE CASCADE)只清 cred 表本身,
  # 不波及 FK 依赖的非凭据表(如 email_thread_state)。
  echo "SET session_replication_role = replica;"
  for t in $CRED_TABLES; do echo "DELETE FROM $t;"; done
  cat "$WORK/tgt-creds.sql"
  echo "SET session_replication_role = DEFAULT;"
} | docker exec -i "$TGT_PG" psql -U ezagent -d "ezagent_${TARGET}" -q -v ON_ERROR_STOP=1 >/dev/null

echo "==> reflow done: $TARGET 现在带 stable 的数据 + $TARGET 自己的 credentials,迁移已跑。"
