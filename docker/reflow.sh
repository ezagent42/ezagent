#!/usr/bin/env bash
# docker/reflow.sh <beta|nightly> — stable → target FULL data reflow including credentials.
#
# The target pre-production environment becomes a faithful copy of stable for
# migration rehearsal: DB, agent FS, credential grants, tokens, password hashes,
# messages, and credential files all flow through. There is no scrub, no table
# picking, and no target credential restore.
#
# ONE EXCEPTION (security): the per-env cookie-signing key
# runtime/secret_key_base is NOT copied — it is scrubbed on the target after
# the FS copy so entrypoint.prod.sh regenerates a fresh, distinct one. Without
# this, stable's secret bleeds into beta/nightly and a session cookie minted on
# stable verifies across the shared .ezagent.chat cookie domain (cross-env
# auth-cookie bleed). See step [3/5].
#
# One-way only: stable is always the source; beta/nightly are the only targets.
# This script never writes stable.
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

compose() { docker-compose --env-file "$SECRETS_HOME/.env.$1" -f docker/docker-compose.yml "${@:2}"; }
pgctr()   { compose "$1" ps -q postgres; }
ezctr()   { compose "$1" ps -q ezagent; }
homevol() { docker inspect "$(ezctr "$1")" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}'; }

SRC_PG=$(pgctr "$SRC"); TGT_PG=$(pgctr "$TARGET")
[ -n "$SRC_PG" ] && [ -n "$TGT_PG" ] || { echo "!! stable/$TARGET stack 未在跑"; exit 3; }
TGT_VOL=$(homevol "$TARGET"); SRC_VOL=$(homevol "$SRC")
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "==> FULL data reflow including credentials: $SRC → $TARGET (work=$WORK)"

# ---- 1. 停目标 ezagent(避免回流时写)----
echo "==> [1/5] 停 $TARGET ezagent"
compose "$TARGET" stop ezagent >/dev/null

# ---- 2. 回流 DB:stable 全量 → 覆盖 target ----
echo "==> [2/5] 回流 DB(stable 全量,含所有凭据/身份/消息表 → $TARGET)"
docker exec "$SRC_PG" pg_dump -U ezagent -d "ezagent_${SRC}" > "$WORK/src-full.sql"
docker exec -i "$TGT_PG" psql -U ezagent -d "ezagent_${TARGET}" -v ON_ERROR_STOP=1 \
  -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' >/dev/null
docker exec -i "$TGT_PG" psql -U ezagent -d "ezagent_${TARGET}" -q < "$WORK/src-full.sql" >/dev/null

# ---- 3. 回流 agent-FS:stable *_home → target *_home(含 credentials 子树)----
# 例外:不回流 stable 的 runtime/secret_key_base —— 它是**每环境独有**的 cookie
# 签名密钥(Plug.Crypto MAC + DownloadToken),不是要演练的迁移数据。若随 cp -a 落到
# 目标,则 stable(app.ezagent.chat)签发的会话 cookie 会在 beta/nightly 通过验签
# (cookie domain=.ezagent.chat 跨子域共享,require_entity 只信签名不回查 DB)→ 跨域
# 登录泄漏。cp 后立即删掉目标上这份文件,entrypoint.prod.sh 下次启动(第 4 步)会
# 重新生成一份**全新且独有**的并持久化(重启稳定)。glob 覆盖任意 profile 名;
# BusyBox sh 下不匹配的 glob 原样传入、rm -f 返回 0。用 `&&` 串 cp→rm:cp 失败则
# rm 不跑、整个 sh -c 以 cp 的非零码退出 → docker run 非零 → 外层 set -e 中止
# (若用 `;` 则 rm 会成为末命令、吞掉 cp 失败)。
echo "==> [3/5] 回流 agent-FS(stable 全量,含 credentials 子树,但剥离 secret_key_base → $TARGET)"
docker run --rm -v "${SRC_VOL}:/src:ro" -v "${TGT_VOL}:/dst" alpine \
  sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; cp -a /src/. /dst/ && rm -f /dst/*/runtime/secret_key_base'

# ---- 4. 起目标 ezagent → 跑 Release.migrate()(= 测试迁移 against prod 数据)----
echo "==> [4/5] 起 $TARGET ezagent → 迁移"
EZAGENT_IMAGE="ezagent:${TARGET}" compose "$TARGET" up -d --no-build --force-recreate --no-deps ezagent >/dev/null
CTR=$(ezctr "$TARGET")
ok=0; for _ in $(seq 1 30); do
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$CTR" 2>/dev/null)" = healthy ] && { ok=1; break; }; sleep 5
done
[ "$ok" = 1 ] || { echo "!! $TARGET 迁移后未 healthy — 暂停,人工查 docker logs $CTR"; exit 4; }

# ---- 5. 完成:target 是 stable 的完整数据副本 ----
echo "==> [5/5] reflow done: $TARGET now has stable FULL data including credentials (except its own regenerated secret_key_base); migration ran and container is healthy."
