# Deploy: three-env stack on a Mac (nightly / beta / stable)

ezagent 在一台 Mac(**OrbStack**)上的生产部署:`nightly → beta → stable` 发布通道阶梯。
设计权威:`docs/superpowers/specs/2026-06-25-deploy-flow-design.md`;实施计划:
`docs/superpowers/plans/2026-06-25-deploy-flow.md`。本文是**可复用的 operator runbook**。

> 取代旧的单环境 `docker-compose.prod.yml`(仍保留作蓝本,标记 superseded — 新部署一律用本文)。

---

## 0. 通道模型(一页看懂)

| 通道 | 域名 | 接入 | git ref | docker tag | 构建 |
|---|---|---|---|---|---|
| **nightly** | `nightly.ezagent.chat` | tailscale sidecar + Caddy(仅 tailnet) | `main` HEAD | `:nightly` | 每晚 cron build `main` |
| **beta** | `beta.ezagent.chat` | tailscale sidecar + Caddy(仅 tailnet) | `beta` 分支 | `:beta` | **re-tag**(不重编) |
| **stable** | `app.ezagent.chat` | cloudflared(公网) | `release` + `vX.Y.Z` | `:stable` | **re-tag**(不重编) |

- **build once, promote the artifact**:镜像 `ezagent:<sha>` 只构建一次;晋级 = `docker tag` 复用。
  验证过:`ezagent:<sha>` / `:nightly` / `:beta` / `:stable` 共享同一 image ID。
- `main` 是唯一主干;`beta`/`release` 是**只快进的部署指针**(不是 task 分支 — 见 dev-together `close.md` 守则)。
- 三环境各自独立 Postgres + 独立 named volume + 独立 `.env`/secrets;共享 `tailscale + mihomo + caddy` infra。

```
                ┌── ezagent-infra (project) ───────────────────────────────┐
                │  tailscale(ezagent-edge, joins head.h2os.cloud, 100.x)   │
   tailnet ────▶│   └─ caddy (network_mode: service:tailscale, DNS-01)      │
   (nightly/beta)│        └─ reverse_proxy ezagent-nightly/beta:10042       │
                │  mihomo :7897 (agent egress, JustMySocks)                 │
                └──────────────── ezagent_edge (external net) ─────────────┘
   公网 ───▶ cloudflared(stable stack) ─▶ ezagent-stable:10042  (app.ezagent.chat)
   本机 ───▶ 127.0.0.1:1004{1,2,3}  admin/rpc fallback(loopback,非 tailnet)
   每通道私有网: ezagent ↔ postgres(PG 永不外露)
```

---

## 1. 环境前置(本机已满足,换机时核对)

- **OrbStack** 运行中(`app.start_at_login: true`)。docker server 29.x。
- **关键:OrbStack 用 `docker-compose`(连字符,v5.x),不是 `docker compose` 子命令插件** —— 所有命令/脚本用 `docker-compose`。
- **镜像拉取走代理**(Docker Hub 被墙):`orb config set network_proxy http://127.0.0.1:7896`(本机已设)。
- **build 代理**:ezagent 镜像 build 时 mihomo 还没起,走 host clash → `host.docker.internal:7897`。
  前置:host clash/mihomo 在 `7897`(及 `7896`)常驻。校验:`docker run --rm alpine nc -z host.docker.internal 7897`。
- **Tailscale/Headscale**:控制面 `https://head.h2os.cloud`;本机已加入(host IP `100.64.0.27`)。
- **Time Machine**:OrbStack `data_allow_backup: false`(默认,已核)→ 8TB `data.img` 已排除,无需 `tmutil`。
  ezagent 状态靠 §6 逻辑备份 → `./backups/`(TM `[Included]`)。

### secrets(全部 gitignored,放主 checkout `docker/`)
- `docker/.env.infra`：`JMS_SUBSCRIPTION_URL`(JustMySocks 订阅,可从 clash-verge `profiles.yaml` 取)、
  `CF_API_TOKEN`(`docker/secrets-prod/cf_api_token`,需 Zone:DNS:Edit)、`TS_AUTHKEY`(见下)。
- `docker/.env.<channel>` + `docker/secrets-<channel>/ezagent.env`(`EZAGENT_COOKIE` == `RELEASE_COOKIE`,同值)。

### 生成 Headscale preauth key(infra 必需)
在控制面机生成,**贴在单独一行**(避免粘连损坏):
```bash
ssh head.h2os.cloud headscale preauthkeys create --user 45 --reusable --expiration 24h
```
写入 `docker/secrets-prod/headscale_authkey`,再进 `docker/.env.infra` 的 `TS_AUTHKEY`。
> 校验:`tailscale up` 报 `failed to parse auth-key: hash length mismatch` = key 损坏/格式错,重新生成。

---

## 2. 一次性 operator setup

```bash
# A. OrbStack 拉取代理(墙)
orb config set network_proxy http://127.0.0.1:7896

# B. infra secrets
#    docker/.env.infra: JMS_SUBSCRIPTION_URL / CF_API_TOKEN / TS_AUTHKEY  (chmod 600)

# C. 每通道 env + cookie(同值)
for c in nightly beta stable; do
  # docker/.env.$c (CHANNEL/EZAGENT_IMAGE/PUBLIC_HOST/HOST_ADMIN_PORT 见 §0/.env.channel.example)
  CK=$(openssl rand -hex 24); printf 'EZAGENT_COOKIE=%s\nRELEASE_COOKIE=%s\n' "$CK" "$CK" > docker/secrets-$c/ezagent.env
done

# D. self-hosted GitHub runner(部署执行器;无公网入站)
TOK=$(gh api --method POST /repos/ezagent42/ezagent/actions/runners/registration-token --jq .token)
cd ~/actions-runner && ./config.sh --url https://github.com/ezagent42/ezagent --token "$TOK" \
  --name ezagent-mac --labels self-hosted,macos,ezagent-deploy --unattended --replace
./svc.sh install && ./svc.sh start
gh api /repos/ezagent42/ezagent/actions/runners --jq '.runners[]|select(.name=="ezagent-mac").status'  # online

# E. GitHub:保护 beta/release 分支 + Environments(stable required reviewers)
# F. launchd 备份(渲染绝对路径)
DEPLOY_DIR=$(pwd); sed "s#__DEPLOY_DIR__#${DEPLOY_DIR}#" docker/com.ezagent.backup.plist.example \
  > ~/Library/LaunchAgents/com.ezagent.backup.plist && launchctl load ~/Library/LaunchAgents/com.ezagent.backup.plist
```

---

## 3. 起 infra(独立生命周期,**不与 channel compose 合并**)

```bash
docker-compose --env-file docker/.env.infra -f docker/docker-compose.infra.yml up -d --build
# 核对 tailscale 拿到 100.x(这是 nightly/beta tailnet 入口的根)
docker exec ezagent-infra-tailscale-1 tailscale ip -4          # → 100.x  (= $TS_IP)
docker inspect --format '{{.State.Health.Status}}' ezagent-infra-mihomo-1   # healthy
```

### nightly/beta 的 DNS A 记录 → ts 容器 100.x(`proxied:false`)
```bash
TS_IP=$(docker exec ezagent-infra-tailscale-1 tailscale ip -4 | head -1)
TOKEN=$(tr -d '[:space:]' < docker/secrets-prod/cf_api_token); ZONE=b170a6fb027620aa3c0ff1dbc60c6c2f
for name in nightly beta; do
  curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
    -d "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$TS_IP\",\"proxied\":false,\"comment\":\"ezagent $name — tailnet only\"}" | jq .success
done
# 验证:从另一台 tailnet 机器 curl -sI https://nightly.ezagent.chat/ → 200/302 且证书有效;tailnet 外连不通。
docker exec ezagent-infra-tailscale-1 getent hosts ezagent-nightly   # Caddy 经共享 netns 解析 upstream
```

---

## 4. 日常:部署与晋级

部署执行器是 `docker/deploy.sh <channel>`(自托管 runner 在 push/cron 时调用;本地也可手动跑):
- 确保 infra 在跑 → 算 SHA=`git rev-parse --short HEAD` → **仅 nightly 允许 build**,beta/stable 缺镜像 **fail-closed** →
  `docker tag` 到通道 → `up --force-recreate ezagent` → 校验运行容器 image ID == 目标 → health(`docker inspect`)→ 失败回滚。

```bash
# nightly(本地或 runner 经 cron):build + 部署
docker/deploy.sh nightly

# 晋级 nightly → beta(部署同一测过的镜像,re-tag 不重编)
git branch -f beta <main-sha> && git push origin beta        # runner 收 push → deploy.sh beta
# 晋级 beta → stable(打版本号;版本固定 0.1.0 起)
git branch -f release beta && git tag v0.1.0 release && git push origin release v0.1.0

# 校验 promotion invariant
for t in <sha> beta stable; do docker image inspect ezagent:$t --format '{{.Id}}'; done   # 应全相同
```

### 回滚
```bash
git branch -f release <prev-sha> && git push -f origin release   # runner re-tag 旧镜像 + force-recreate
# 或本地: docker tag ezagent:<prev-sha> ezagent:stable && docker-compose --env-file docker/.env.stable \
#         -f docker/docker-compose.yml --profile stable up -d --no-build --force-recreate --no-deps ezagent
```

---

## 5. 状态查询

```bash
docker ps --filter name=ezagent- --format '{{.Names}}: {{.Status}}'
docker volume ls | grep -E 'ezagent-(nightly|beta|stable)_(home|pg)'   # 6 个隔离卷
curl -sI http://127.0.0.1:10041/   # nightly admin (loopback);beta 10042;stable 10043
curl -sI https://app.ezagent.chat/ # stable 公网
```

---

## 6. 备份与恢复

```bash
docker/backup.sh <channel>   # → backups/<channel>/<ts>/{db.sql.gz, fs-snapshot.tar.gz, manifest.json}
```
- **域1 Postgres**:`pg_dump`(逻辑、一致);**域2 Agent FS**:`*_home` 卷精选 tar(跳过 node_modules/_build/deps)。
- manifest 记 `git_sha` + `running_image`(digest)+ dump 起止 + `atomic:false`(两域非单一致快照)。
- launchd 每日 04:00 跑三通道;TM 备份 `backups/`(逻辑、可单文件恢复),不碰 OrbStack `data.img`。

恢复(各域独立):`gzip -dc db.sql.gz | docker exec -i <pg_ctr> psql -U ezagent -d ezagent_<channel>`;
FS:解 `fs-snapshot.tar.gz` 回 `*_home` 卷。跨域一致性快照(quiesce+LSN)留后续迭代。

---

## 7. 故障排查

- **`docker compose` unknown command** → 用 `docker-compose`(本机无插件子命令)。
- **镜像拉取 Bad Gateway** → `orb config get network_proxy` 应 `http://127.0.0.1:7896`。
- **tailscale Restarting / auth-key parse error** → preauth key 损坏,重新生成(§1)并 `docker-compose --env-file docker/.env.infra -f docker/docker-compose.infra.yml up -d tailscale`。
- **nightly/beta tailnet TCP 通但 TLS reset(从 host 自测)** → 本机有用户自有 host caddy(launchd,`~/.config/caddy/Caddyfile`)占 `*:443`,遮蔽 docker 发布。这正是用 **sidecar**(绑 sidecar 自己的 100.x:443,不碰 host :443)的原因 —— 不要把 docker caddy 绑 host `100.64.0.27:443`。验证:`lsof -nP -iTCP:443 -sTCP:LISTEN`。(替代:若想复用 host caddy,在 `~/.config/caddy/Caddyfile` 加 nightly/beta vhost 反代 `127.0.0.1:10041/10042`,DNS A 指 host 100.64.0.27。)
- **Caddy 取不到证书** → CF token 缺 Zone:DNS:Edit;或 DNS A 记录 `proxied:true`(必须 false)。
- **stable `app.ezagent.chat` 530** → cloudflared 没连上 / ezagent-stable 未 healthy;`docker logs ezagent-stable-cloudflared-1`。
- **build 拉依赖失败** → host clash 未在 7897;`docker run --rm alpine nc -z host.docker.internal 7897`。
- **重启后** → OrbStack 自启;确认 `ezagent-edge` tailscale 节点在线 + 各 stack `up`。
