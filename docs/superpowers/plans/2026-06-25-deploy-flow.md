# Deploy Flow Implementation Plan — nightly / beta / stable

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在一台 Mac(OrbStack)上把现有单环境 prod stack 扩成 `nightly→beta→stable` 三环境晋级阶梯,含 self-hosted-runner CI/CD、双域逻辑备份。

**Architecture:** 参数化单份 `docker-compose.yml`(按 `CHANNEL` + `.env.<channel>` 起三个 compose project)+ 一份共享 `docker-compose.infra.yml`(mihomo 出口 + Caddy 入口)。两层网络:每环境私有网(PG)+ 共享 edge 网(mihomo/Caddy/cloudflared)。镜像 build-once,晋级靠 re-tag。

**Tech Stack:** OrbStack(docker 29.x)、docker compose、Caddy(自编 cloudflare-dns 模块,DNS-01)、cloudflared、GitHub Actions self-hosted runner、bash、launchd。

## Global Constraints

- 本机 = macOS 26 Tahoe(`Darwin 25.x`);本机 host 的 Headscale IP = `100.64.0.27`(`h2oslabs-internal-server`)。
  **但 nightly/beta 入口不绑 host IP** —— 用 tailscale sidecar 容器(hostname `ezagent-edge`)拿**它自己的** 100.x(部署时发现)。
- Headscale 控制面 = `https://head.h2os.cloud`;sidecar 加入需 **operator 提供的 preauth key**(`TS_AUTHKEY`)。
- 通道命名一词贯穿:`nightly` / `beta` / `stable`;域名 `nightly.ezagent.chat` / `beta.ezagent.chat` / `app.ezagent.chat`。
- 主干不反转:`main` 唯一主干;`beta`/`release` 仅快进指针;`stable` 发布打 `vX.Y.Z` tag。
- **build once, promote the artifact**:镜像 `ezagent:<sha>` 构建一次,晋级 `docker tag` 复用,**不重编**。
- host admin 端口:nightly `10041` / beta `10042` / stable `10043`,**绑 `127.0.0.1`**(本地 rpc/debug,避开 OrbStack host-utun 绑定坑),容器内固定 `10042`。
- nightly/beta 仅 tailnet 可达:**tailscale sidecar**(`ezagent-edge`)+ Caddy `network_mode: service:tailscale` 在 ts 的 tailnet IP 上 listen:443;DNS A 记录 `nightly|beta.ezagent.chat → <ts 容器 100.x>`(`proxied:false`)。
- 存储用 named volume;备份是逐域逻辑备份(`pg_dump` + 精选 FS 快照)→ `./backups/<channel>/`。
- **Time Machine 必须排除** `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data`。
- secrets 分环境且 gitignored:`docker/.env.<channel>` + `docker/secrets-<channel>/`,各自独立 `POSTGRES_PASSWORD`。
- repo `ezagent42/ezagent`;`gh` 已认证(allenwoods,ADMIN,scopes 含 `repo`+`workflow`)→ runner 注册 token 可由 `gh api` mint。
- 不碰 ezagent `.ex` 应用代码(纯 infra);邮件保持现状(spec §10 deferred)。
- 所有 operator 一次性步骤完成后必须写进 `docs/guide/deploy-mac-stack.md`(三环境 runbook),可复用。

参考 spec:`docs/superpowers/specs/2026-06-25-deploy-flow-design.md`(权威设计)。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `docker/docker-compose.yml` | 参数化的单通道 stack(postgres + ezagent),attach 私有网+edge 网 | Create(由 `docker-compose.prod.yml` 重构而来) |
| `docker/docker-compose.infra.yml` | 共享 mihomo + Caddy(+ external edge 网定义) | Create |
| `docker/.env.nightly` / `.env.beta` / `.env.stable` | 各通道参数 + secrets 引用(gitignored) | Create(+ `.env.channel.example`) |
| `docker/caddy/Dockerfile` | 自编带 `caddy-dns/cloudflare` 的 Caddy 镜像 | Create |
| `docker/caddy/Caddyfile` | nightly/beta site-block,DNS-01;经 ts netns 在 tailnet IP listen | Create |
| `docker/docker-compose.infra.yml` 内 `tailscale` 服务 | sidecar 加入 Headscale,Caddy 共享其 netns | Create(Task 3) |
| `docker/.env.infra` | infra secrets:`JMS_SUBSCRIPTION_URL`/`CF_API_TOKEN`/`TS_AUTHKEY`(gitignored) | Create(operator) |
| `docker/cloudflared/{nightly,beta}` | n/a(nightly/beta 走 Caddy,不用 cloudflared) | — |
| `docker/cloudflared/stable-config.yml` | stable 隧道配置(复用现有 prod-config.yml) | Rename/Create |
| `docker/deploy.sh` | `deploy.sh <channel>`:build-or-retag→up→migrate→健康/smoke→失败回滚 | Create |
| `docker/backup.sh` | `backup.sh <channel>`:pg_dump + 精选 FS 快照 → ./backups/<channel>/ | Create |
| `docker/com.ezagent.backup.plist` | launchd 定时备份 | Create |
| `.github/workflows/deploy.yml` | nightly cron + push[beta,release] → 调 deploy.sh(self-hosted) | Create |
| `docs/guide/deploy-mac-stack.md` | 升级为三环境 runbook(含所有 operator 步骤) | Modify |
| `docker/docker-compose.prod.yml` | 删除(被参数化版取代) | Delete(末尾) |

> 验证方式说明:本计划是 infra-as-code,"测试"= 验证命令(`docker-compose config`、`bash -n`、`docker-compose up`+健康检查、`curl`)。每个任务的 TDD 节奏 = 先写/跑验证命令确认"制品缺失即失败"→ 造制品 → 验证命令通过 → commit。

---

## Milestone A — Infra 基础 + nightly 端到端跑通

### Task 1: 参数化 compose(单通道 postgres + ezagent + 两层网络)

**Files:**
- Create: `docker/docker-compose.yml`
- Reference: `docker/docker-compose.prod.yml`(现有,作为蓝本)

**Interfaces:**
- Produces:compose 读以下 env(由 `.env.<channel>` 提供):`CHANNEL`、`EZAGENT_IMAGE`、`PUBLIC_HOST`、`HOST_ADMIN_PORT`、`POSTGRES_PASSWORD`、`SECRETS_DIR`。
- Produces:edge 网络名 `ezagent_edge`(external,由 Task 3 创建);ezagent 在 edge 网的 alias = `ezagent-${CHANNEL}`。

- [ ] **Step 1: 写验证(制品应缺失)**

Run: `test ! -f docker/docker-compose.yml && echo MISSING`
Expected: 打印 `MISSING`

- [ ] **Step 2: 创建参数化 compose**

由 `docker-compose.prod.yml` 重构:**删掉 mihomo 与 cloudflared 服务**(mihomo 进 infra;cloudflared 仅 stable,见 Task 9),`name` / db / image / 端口 / 公有 host 全参数化,加两层网络。

```yaml
# docker/docker-compose.yml — 参数化单通道 stack(nightly/beta/stable 共用)
# 用法(channel 只用本文件,infra 独立起 —— codex 致命#1,绝不 -f 合并 infra):
#   docker-compose --env-file docker/.env.<channel> -f docker/docker-compose.yml up -d   (见 docker/deploy.sh)
# infra 单独: docker-compose --env-file docker/.env.infra -f docker/docker-compose.infra.yml up -d
name: ezagent-${CHANNEL:?set CHANNEL in .env.<channel>}

services:
  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_USER: ezagent
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}
      POSTGRES_DB: ezagent_${CHANNEL}
    volumes:
      - pg:/var/lib/postgresql/data
    networks: [private]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ezagent -d ezagent_${CHANNEL}"]
      interval: 5s
      timeout: 5s
      retries: 20

  ezagent:
    build:
      context: ..
      dockerfile: docker/Dockerfile.prod
      args:
        HTTP_PROXY: ${DOCKER_BUILD_PROXY:-}
        HTTPS_PROXY: ${DOCKER_BUILD_PROXY:-}
        NO_PROXY: "localhost,127.0.0.1,::1"
    image: ${EZAGENT_IMAGE:?set EZAGENT_IMAGE}
    restart: unless-stopped
    ports:
      # 本地 admin/rpc/debug fallback — 绑 loopback,避开 OrbStack host-utun 绑定坑。
      # tailnet 访问走 tailscale sidecar + Caddy(见 Task 3/5),不靠这个端口。
      - "127.0.0.1:${HOST_ADMIN_PORT:?set HOST_ADMIN_PORT}:10042"
    env_file:
      - ${SECRETS_DIR:?set SECRETS_DIR}/ezagent.env
    environment:
      PORT: "10042"
      SHELL: /bin/bash
      EZAGENT_HOME: /data
      EZAGENT_PROFILE: default
      EZAGENT_PUBLIC_HOST: ${PUBLIC_HOST:?set PUBLIC_HOST}
      EZAGENT_PUBLIC_SCHEME: https
      DATABASE_URL: ecto://ezagent:${POSTGRES_PASSWORD}@postgres:5432/ezagent_${CHANNEL}
      POOL_SIZE: ${POOL_SIZE:-5}
      EZAGENT_EXTRA_CHECK_ORIGINS: "https://${PUBLIC_HOST},http://127.0.0.1:${HOST_ADMIN_PORT},http://localhost:${HOST_ADMIN_PORT}"
      RELEASE_DISTRIBUTION: name
      RELEASE_NODE: ezagent_runtime@127.0.0.1
      HTTP_PROXY: ${ESR_PROXY:-http://mihomo:7897}
      HTTPS_PROXY: ${ESR_PROXY:-http://mihomo:7897}
      http_proxy: ${ESR_PROXY:-http://mihomo:7897}
      https_proxy: ${ESR_PROXY:-http://mihomo:7897}
      NO_PROXY: "localhost,127.0.0.1,::1,postgres,mihomo,host.docker.internal,.feishu.cn,.larksuite.com,open.feishu.cn"
      no_proxy: "localhost,127.0.0.1,::1,postgres,mihomo,host.docker.internal,.feishu.cn,.larksuite.com,open.feishu.cn"
    volumes:
      - home:/data
      - ${SECRETS_DIR}:/secrets:ro
      - ./entrypoint.prod.sh:/app/entrypoint.prod.sh:ro
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      private: {}
      edge:
        aliases: ["ezagent-${CHANNEL}"]
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:10042/"]
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 40s

volumes:
  home:   # 通道 profile(凭据/snapshot/日志/agent 工作目录)→ ezagent-<channel>_home
  pg:     # Postgres 数据 → ezagent-<channel>_pg

networks:
  private:        # 仅本通道:ezagent ↔ postgres
  edge:           # 共享:mihomo/Caddy/cloudflared(由 infra 创建为 external)
    external: true
    name: ezagent_edge
```

- [ ] **Step 3: 语法校验(此时 infra/env 未就绪,预期报缺 external 网或 env)**

Run: `CHANNEL=nightly EZAGENT_IMAGE=x PUBLIC_HOST=x HOST_ADMIN_PORT=10041 POSTGRES_PASSWORD=x SECRETS_DIR=./secrets-nightly docker-compose -f docker/docker-compose.yml config -q; echo $?`
Expected: 报 `network ezagent_edge declared as external, but could not be found`(说明 YAML 本身合法,仅缺 external 网)→ 该错误在 Task 3 后消失。

- [ ] **Step 4: Commit**

```bash
git add docker/docker-compose.yml
git commit -m "feat(deploy): parameterized single-channel compose (2-tier networks)"
```

---

### Task 2: 通道 env 文件 + secrets 布局

**Files:**
- Create: `docker/.env.channel.example`(committed 模板)
- Create(gitignored,operator 造): `docker/.env.nightly`、`docker/secrets-nightly/ezagent.env`、`docker/secrets-nightly/mihomo/config.yaml`

**Interfaces:**
- Consumes:Task 1 的 compose 变量。
- Produces:`docker/.env.<channel>` 提供 `CHANNEL/EZAGENT_IMAGE/PUBLIC_HOST/HOST_ADMIN_PORT/POSTGRES_PASSWORD/SECRETS_DIR/JMS_SUBSCRIPTION_URL/DOCKER_BUILD_PROXY`。

- [ ] **Step 1: 先补 .gitignore(codex 高#9:现状只忽略根 `.env`,会误提交 secrets)— 必须先做**

在 `.gitignore` 末尾追加(committed):
```
# deploy flow per-channel secrets
docker/.env
docker/.env.*
!docker/.env.channel.example
docker/secrets-*/
docker/.env.infra
```

- [ ] **Step 2: 验证忽略生效(任何 secret 文件创建前必须绿)**

Run: `git check-ignore docker/.env.nightly docker/.env.infra docker/secrets-nightly/ezagent.env && echo IGNORED_OK`
Expected: 打印三路径 + `IGNORED_OK`。**不绿不许往下造任何 secret。**

- [ ] **Step 3: 写 committed 模板**

```bash
# docker/.env.channel.example — 复制为 docker/.env.<channel> 后填值
CHANNEL=nightly
EZAGENT_IMAGE=ezagent:nightly
PUBLIC_HOST=nightly.ezagent.chat
HOST_ADMIN_PORT=10041
SECRETS_DIR=./secrets-nightly
POSTGRES_PASSWORD=__CHANGE_ME__
JMS_SUBSCRIPTION_URL=__JMS_SUB_URL__         # infra/mihomo 用
DOCKER_BUILD_PROXY=http://host.docker.internal:7897
```

- [ ] **Step 4: operator 造 nightly 实例(我执行,记入 runbook)**

```bash
cp docker/.env.channel.example docker/.env.nightly   # 填 POSTGRES_PASSWORD(openssl rand -hex 16)、JMS URL
mkdir -p docker/secrets-nightly/mihomo
# ezagent.env: codex 高#10 —— EZAGENT_COOKIE 必须 == RELEASE_COOKIE(现有 runtime+rpc 依赖),用同一个值
COOKIE=$(openssl rand -hex 24)
printf 'EZAGENT_COOKIE=%s\nRELEASE_COOKIE=%s\n' "$COOKIE" "$COOKIE" > docker/secrets-nightly/ezagent.env
# mihomo config 见 Task 3
```

- [ ] **Step 5: Commit(仅模板,secrets 不入库)**

```bash
git add docker/.env.channel.example .gitignore
git commit -m "feat(deploy): per-channel env template + secrets layout"
```

---

### Task 3: 共享 infra compose(mihomo + Caddy + edge 网)

**Files:**
- Create: `docker/docker-compose.infra.yml`
- Create: `docker/caddy/Dockerfile`
- Reference: 现有 `docker/mihomo/config.template.yaml`、`docker/mihomo/render-config.sh`

**Interfaces:**
- Produces:external 网 `ezagent_edge`;edge 上的服务别名 `mihomo`(出口代理 :7897)、`caddy`(入口)。

- [ ] **Step 1: 写 Caddy 自编镜像(官方镜像不含 cloudflare DNS 模块)**

```dockerfile
# docker/caddy/Dockerfile — Caddy + caddy-dns/cloudflare(DNS-01 必需)
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

- [ ] **Step 2: 写 infra compose**

```yaml
# docker/docker-compose.infra.yml — 共享出口(mihomo)+ 入口(Caddy);三通道共用一份
name: ezagent-infra

services:
  mihomo:
    image: metacubex/mihomo:latest
    restart: unless-stopped
    environment:
      JMS_SUBSCRIPTION_URL: ${JMS_SUBSCRIPTION_URL:?set JMS_SUBSCRIPTION_URL}
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        mkdir -p /root/.config/mihomo
        sh /etc/mihomo/render-config.sh /etc/mihomo/config.template.yaml /root/.config/mihomo/config.yaml
        exec "$$(command -v mihomo || echo /mihomo)" -d /root/.config/mihomo
    volumes:
      - ./mihomo/config.template.yaml:/etc/mihomo/config.template.yaml:ro
      - ./mihomo/render-config.sh:/etc/mihomo/render-config.sh:ro
    networks:
      edge: { aliases: ["mihomo"] }
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 7897 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 10s

  # tailscale sidecar:加入 Headscale,拿自己的 100.x。Caddy 共享其 netns。
  tailscale:
    image: tailscale/tailscale:latest
    hostname: ezagent-edge
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY:?set TS_AUTHKEY (headscale preauth key) in docker/.env.infra}
      TS_EXTRA_ARGS: "--login-server=https://head.h2os.cloud --accept-dns=false"
      TS_HOSTNAME: ezagent-edge
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "false"          # kernel 模式:需 /dev/net/tun + NET_ADMIN(可在 tailnet IP 上 bind)
    volumes:
      - ts_state:/var/lib/tailscale
    devices:
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    networks: [edge]                 # Caddy 经共享 netns 借此 resolve ezagent-<channel>
    restart: unless-stopped

  caddy:
    build: { context: ./caddy }
    image: ezagent-caddy:latest
    restart: unless-stopped
    # 共享 tailscale 的 netns → Caddy 直接在 ts 容器的 tailnet 100.x 上 listen:443。
    # 不发布任何 host 端口(避开 OrbStack host-utun 绑定坑)。
    network_mode: "service:tailscale"
    depends_on:
      tailscale:
        condition: service_started
    environment:
      CF_API_TOKEN: ${CF_API_TOKEN:?set CF_API_TOKEN (Zone:DNS:Edit for ezagent.chat) in docker/.env.infra}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data

volumes:
  caddy_data:
  ts_state:

networks:
  edge:
    name: ezagent_edge
```

- [ ] **Step 3: 校验 infra 语法**

Run: `JMS_SUBSCRIPTION_URL=x CF_API_TOKEN=x TS_AUTHKEY=x docker-compose -f docker/docker-compose.infra.yml config -q && echo OK`
Expected: `OK`

> infra 的 secrets 放 gitignored `docker/.env.infra`(`JMS_SUBSCRIPTION_URL` / `CF_API_TOKEN` / `TS_AUTHKEY`);
> 起栈时 `--env-file docker/.env.infra`。`CF_API_TOKEN` 需 Zone:DNS:Edit(Task 5 Step1 验证);`TS_AUTHKEY`
> 由 operator 在 head.h2os.cloud 生成(`headscale preauthkeys create --user <u> --reusable`)。

- [ ] **Step 4: Commit**

```bash
git add docker/docker-compose.infra.yml docker/caddy/Dockerfile
git commit -m "feat(deploy): shared infra (tailscale sidecar + mihomo egress + caddy cloudflare-dns ingress)"
```

---

### Task 4: Caddyfile(nightly/beta,经 ts netns 在 tailnet IP listen,Cloudflare DNS-01)

**Files:**
- Create: `docker/caddy/Caddyfile`

**Interfaces:**
- Consumes:edge 网别名 `ezagent-nightly` / `ezagent-beta`(Task 1,经共享的 tailscale netns resolve);`CF_API_TOKEN`(Task 3)。
- 说明:Caddy `network_mode: service:tailscale`(Task 3)→ `:443` 即 ts 容器的 tailnet 100.x;无需绑 host。

- [ ] **Step 1: 写 Caddyfile**

```caddyfile
# docker/caddy/Caddyfile — nightly/beta 入口;TLS 走 Cloudflare DNS-01(无需公网端口验证)
{
	# DNS-01:Caddy 自动为下面的 host 签 Let's Encrypt 证书
}

nightly.ezagent.chat {
	tls {
		dns cloudflare {env.CF_API_TOKEN}
	}
	reverse_proxy ezagent-nightly:10042
}

beta.ezagent.chat {
	tls {
		dns cloudflare {env.CF_API_TOKEN}
	}
	reverse_proxy ezagent-beta:10042
}
```

- [ ] **Step 2: 校验 Caddyfile 语法(用自编镜像)**

Run:
```bash
docker build -t ezagent-caddy:latest docker/caddy
docker run --rm -v "$PWD/docker/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" ezagent-caddy:latest caddy validate --config /etc/caddy/Caddyfile
```
Expected: `Valid configuration`

- [ ] **Step 3: Commit**

```bash
git add docker/caddy/Caddyfile
git commit -m "feat(deploy): Caddyfile for nightly/beta (cloudflare DNS-01, tailnet bind)"
```

---

### Task 5: nightly 端到端跑通(operator + 验证)

**Files:** 无新代码;operator 步骤 + 验证。所有步骤记入 `docs/guide/deploy-mac-stack.md`。

- [ ] **Step 1: 验证/准备 CF DNS-edit token**

Run(用现有 ezagent-cf-token 试探 DNS 列举权限):
```bash
TOKEN=$(tr -d '[:space:]' < docker/secrets-prod/cf_api_token); ZONE=b170a6fb027620aa3c0ff1dbc60c6c2f
curl -s -H "Authorization: Bearer $TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?per_page=1" | jq '.success'
```
Expected: `true` → token 可读 DNS。若 Caddy DNS-01 失败(需 edit),operator 在 CF dashboard 建一个 Zone:DNS:Edit + Zone:Zone:Read 的专用 token,写入 `docker/.env.infra` 的 `CF_API_TOKEN`(gitignored)。记入 runbook。

- [ ] **Step 2: 起 infra,确认 ts 加入 Headscale 并拿到 100.x(取代 host-bind 验证)**

```bash
docker-compose --env-file docker/.env.infra -f docker/docker-compose.infra.yml up -d --build
# ts 进 kernel 模式 + 拿到 tailnet IP(这是新的 de-risk 点:验证 OrbStack VM 内 /dev/net/tun 可用)
docker exec ezagent-infra-tailscale-1 tailscale ip -4
docker exec ezagent-infra-tailscale-1 tailscale status | head -3
```
Expected:`tailscale ip -4` 输出一个 `100.x` 地址(记为 `$TS_IP`,即 `ezagent-edge` 节点);status 显示已连 `head.h2os.cloud`。若报 `CONFIG_TUN`/tun 缺失 → OrbStack VM tun 不可用,暂停上报(见 §风险)。

- [ ] **Step 3: operator 建 nightly 的 DNS A 记录 → `$TS_IP`(ts 容器的 100.x)**

```bash
TS_IP=$(docker exec ezagent-infra-tailscale-1 tailscale ip -4 | head -1)
TOKEN=$(tr -d '[:space:]' < docker/secrets-prod/cf_api_token); ZONE=b170a6fb027620aa3c0ff1dbc60c6c2f
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  -d "{\"type\":\"A\",\"name\":\"nightly\",\"content\":\"$TS_IP\",\"proxied\":false,\"comment\":\"ezagent nightly — tailnet only\"}" | jq '{success, name: .result.name, content: .result.content}'
```
Expected: `success:true`,name `nightly.ezagent.chat`,content = `$TS_IP`。(`proxied:false` 关键——不能走 CF 代理,否则公网会试图连私网 IP。)

- [ ] **Step 4: 起 nightly stack(只用 channel compose,不混 infra 文件 —— codex 致命#1)**

```bash
docker-compose --env-file docker/.env.nightly -f docker/docker-compose.yml up -d --build
```
> 注:infra(Step 2)已独立起;channel 经 external `ezagent_edge` 连。首次 `--build` 编译 ezagent 镜像
> (GFW fetch 走 `DOCKER_BUILD_PROXY=host.docker.internal:7897`,**前置:host clash 在 7897/7896 在跑**);
> 后续由 deploy.sh 控制 build/re-tag。

- [ ] **Step 4b: 验证 Caddy 经 ts netns 能解析+到达 upstream(codex#11,共享 netns 关键假设)**

```bash
# tailscale 容器的 netns 内(Caddy 与之共享):解析 ezagent-nightly + 访问 upstream
docker exec ezagent-infra-tailscale-1 getent hosts ezagent-nightly
docker exec ezagent-infra-caddy-1 wget -qO- http://ezagent-nightly:10042/ >/dev/null && echo UPSTREAM_OK
```
Expected: `getent` 解析出 edge 网内 IP;`UPSTREAM_OK`。**若解析失败** → Caddy 仅共享 netns 拿不到 edge DNS,
退路:让 Caddy **直接加入 edge 网络**(去掉 `network_mode`,但那样就不在 tailnet 上 listen)→ 暂停上报,
改用"ts 容器跑 Caddy 二进制"或 per-env ts。

- [ ] **Step 5: 验证健康 + tailnet 可达 + 公网不可达**

```bash
docker-compose --env-file docker/.env.nightly -f docker/docker-compose.yml ps   # ezagent + postgres healthy
# Caddy 在 ts netns 内,经 tailnet IP 服务;从另一台 tailnet 机器验证:
#   curl -sI https://nightly.ezagent.chat/  → 200/302(DNS-01 证书有效)
# 从 tailnet 外: 解析到 $TS_IP(CGNAT)但连不通(预期 → 证明仅 tailnet 可达)
docker exec ezagent-nightly-ezagent-1 curl -fsS http://localhost:10042/ >/dev/null && echo APP_OK
```
Expected: 容器 healthy;`APP_OK`;tailnet 内 `nightly.ezagent.chat` 返回 200/302 且证书有效;tailnet 外超时。

- [ ] **Step 6: Commit runbook 草稿**

```bash
git add docs/guide/deploy-mac-stack.md   # 记下 Step1-5 的实际命令与结果(含 $TS_IP)
git commit -m "docs(deploy): nightly bring-up runbook (operator steps)"
```

---

## Milestone B — 部署自动化(deploy.sh + runner + workflow)

### Task 6: `deploy.sh <channel>`(build-or-retag → up → 健康 → 回滚)

**Files:**
- Create: `docker/deploy.sh`

**Interfaces:**
- Consumes:`.env.<channel>`、两份 compose。
- Produces:`docker/deploy.sh <nightly|beta|stable>`;约定镜像 `ezagent:<sha>` + 通道 tag `ezagent:<channel>`。

- [ ] **Step 1: 写 deploy.sh**

```bash
#!/usr/bin/env bash
# docker/deploy.sh <channel> — build-once/promote-artifact 部署 + 健康检查 + 回滚
# codex 致命#1/#2:infra 独立生命周期(自带 .env.infra),channel 只用自己的 compose,
#   经 external ezagent_edge 连通。绝不把 infra 文件混进 channel 命令(否则合成单 project + 缺 infra env)。
set -euo pipefail
CHANNEL="${1:?usage: deploy.sh <nightly|beta|stable>}"
cd "$(dirname "$0")/.."
case "$CHANNEL" in nightly|beta|stable) : ;; *) echo "unknown channel $CHANNEL"; exit 2 ;; esac
ENVFILE="docker/.env.${CHANNEL}"

# channel compose:project 名来自 compose 里的 name: ezagent-${CHANNEL};stable 加 cloudflared profile
CH=(docker-compose --env-file "$ENVFILE" -f docker/docker-compose.yml)
[ "$CHANNEL" = stable ] && CH+=(--profile stable)
CTR="ezagent-${CHANNEL}-ezagent-1"   # compose 容器名(project=ezagent-<channel>, service=ezagent)

# 确保共享 infra(tailscale+mihomo+caddy)在跑 —— 独立 project + 独立 env(codex#1/#2)
docker-compose --env-file docker/.env.infra -f docker/docker-compose.infra.yml up -d

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
"${CH[@]}" up -d --no-build
EZAGENT_IMAGE="$CHAN_IMG" "${CH[@]}" up -d --no-build --force-recreate --no-deps ezagent
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
```

- [ ] **Step 2: 语法校验**

Run: `bash -n docker/deploy.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: 实跑 nightly(应复用 Task 5 已构建镜像或重建)**

Run: `chmod +x docker/deploy.sh && docker/deploy.sh nightly`
Expected: 末行 `==> nightly healthy on ezagent:nightly`

- [ ] **Step 4: Commit**

```bash
git add docker/deploy.sh
git commit -m "feat(deploy): deploy.sh — build-once/promote + health + rollback"
```

---

### Task 7: 安装 self-hosted runner(operator,我执行 + 记 runbook)

**Files:** 无代码;记入 `docs/guide/deploy-mac-stack.md`。

- [ ] **Step 0: 安全前置(codex 高#7/#8)— 装 runner 前先满足**
  - **分支保护**:GitHub `beta`/`release` 设 branch protection,限制可 push 人员(push 即在 Mac 上执行该 ref 代码)。
  - **Environments**:repo Settings→Environments 建 `stable`(required reviewers),配合 deploy.yml 的 `environment:`。
  - **build 代理前置**:nightly 在 runner 上 `--build` 时 mihomo 容器可能还没起,build 走
    `host.docker.internal:7897` → **host clash/mihomo 必须在 7897(及 7896 供 OrbStack 拉镜像)常驻**。装 runner 时校验:
    `curl -x http://127.0.0.1:7897 -sI https://registry.npmjs.org | head -1`。
  - **(可选)专用低权用户**跑 runner,限制其文件系统权限。

- [ ] **Step 1: mint 注册 token(gh,admin-gated)**

Run: `gh api --method POST /repos/ezagent42/ezagent/actions/runners/registration-token --jq .token`
Expected: 返回一个 token(1h 过期)。

- [ ] **Step 2: 下载 + 配置 + 装服务**

```bash
RUNNER_DIR="$HOME/actions-runner"; mkdir -p "$RUNNER_DIR"; cd "$RUNNER_DIR"
# macOS arm64 runner(版本取 github 最新)
curl -fsSL -o r.tar.gz https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64.tar.gz || \
  echo "→ 若 latest 不带架构直链,从 https://github.com/actions/runner/releases 取 osx-arm64 链接"
tar xzf r.tar.gz
./config.sh --url https://github.com/ezagent42/ezagent \
  --token "<上一步 token>" --name ezagent-mac --labels self-hosted,macos,ezagent-deploy --unattended
./svc.sh install && ./svc.sh start
```

- [ ] **Step 3: 验证 runner online**

Run: `gh api /repos/ezagent42/ezagent/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'`
Expected: 见 `ezagent-mac` `status:"online"`,labels 含 `ezagent-deploy`。

- [ ] **Step 4: Commit runbook**

```bash
git add docs/guide/deploy-mac-stack.md
git commit -m "docs(deploy): self-hosted runner install runbook"
```

---

### Task 8: `deploy.yml` workflow(nightly cron + push[beta,release])

**Files:**
- Create: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes:self-hosted runner(label `ezagent-deploy`)、`docker/deploy.sh`。

- [ ] **Step 1: 写 workflow**

> **安全(advisor)**:本 workflow 触发器**只有** `schedule` + `push:[beta,release]`,**绝不加 `pull_request`** ——
> 否则 fork PR 的代码会在你的 Mac 上以 `ezagent-deploy` runner 执行(RCE 面)。`ci.yml` 的 PR 门禁继续跑在
> `ubuntu-latest`,与自托管 runner 隔离。

```yaml
# .github/workflows/deploy.yml — 在 Mac 自托管 runner 上部署
name: Deploy
on:
  schedule:
    - cron: '0 19 * * *'   # 每日 19:00 UTC = 03:00 CST → nightly
  push:
    branches: [beta, release]
permissions:
  contents: read              # codex 高#7:最小权限
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false
jobs:
  deploy:
    runs-on: [self-hosted, macos, ezagent-deploy]
    # codex#7:用 GitHub Environment 给 stable(release)加人工审批门(在 repo Settings→Environments 配 required reviewers)
    environment: ${{ github.ref == 'refs/heads/release' && 'stable' || (github.ref == 'refs/heads/beta' && 'beta' || 'nightly') }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Pick channel
        id: ch
        run: |
          if [ "${{ github.event_name }}" = "schedule" ]; then echo "channel=nightly" >> "$GITHUB_OUTPUT"
          elif [ "${{ github.ref }}" = "refs/heads/beta" ]; then echo "channel=beta" >> "$GITHUB_OUTPUT"
          else echo "channel=stable" >> "$GITHUB_OUTPUT"; fi
      - name: Deploy
        run: docker/deploy.sh "${{ steps.ch.outputs.channel }}"
      - name: Smoke (beta only)
        if: steps.ch.outputs.channel == 'beta'
        run: docker/smoke.sh beta   # 见注:VERIFICATION.md 的 smoke flow,本任务先放最小 curl 占位的真实脚本
```

- [ ] **Step 2: 写最小真实 smoke 脚本(beta 门禁)**

```bash
#!/usr/bin/env bash
# docker/smoke.sh <channel> — beta 晋级门禁:最小冒烟(随 VERIFICATION.md 扩充)
set -euo pipefail
CHANNEL="${1:?}"; source "docker/.env.${CHANNEL}"
docker run --rm --network ezagent_edge curlimages/curl:latest \
  -fsS "http://ezagent-${CHANNEL}:10042/" >/dev/null && echo "smoke OK: ${CHANNEL} serving"
```

- [ ] **Step 3: 校验 + 提交触发(beta 空推一次验证 runner 接活)**

Run:
```bash
bash -n docker/smoke.sh
# 校验 workflow YAML
gh workflow view deploy.yml 2>/dev/null || echo "→ 推送后可在 Actions 看到"
```
Expected: `bash -n` 无错。

- [ ] **Step 4: Commit**

```bash
chmod +x docker/smoke.sh
git add .github/workflows/deploy.yml docker/smoke.sh
git commit -m "feat(deploy): deploy.yml (nightly cron + beta/release push) + smoke gate"
```

---

## Milestone C — 扩到三环境

### Task 9: beta + stable stack(env + cloudflared + 晋级实测)

**Files:**
- Create(operator,gitignored):`docker/.env.beta`、`docker/.env.stable`、`docker/secrets-beta/*`、`docker/secrets-stable/*`
- Create: `docker/cloudflared/stable-config.yml`(复用现有 `prod-config.yml` 内容)
- Modify: `docker/docker-compose.yml`(stable 专属 cloudflared,用 compose profile)

**Interfaces:**
- Consumes:Task 1 compose、Task 6 deploy.sh。
- Produces:stable 通道经 cloudflared → app.ezagent.chat;beta 经 Caddy。

- [ ] **Step 1: 给 compose 加 stable-only cloudflared(profile 门控)**

在 `docker/docker-compose.yml` 的 `services:` 末尾追加:

```yaml
  cloudflared:
    profiles: ["stable"]          # 仅 --profile stable 时启用
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: ["tunnel", "--config", "/etc/cloudflared/config.yml", "run"]
    volumes:
      - ./cloudflared/stable-config.yml:/etc/cloudflared/config.yml:ro
      - ${HOME}/.cloudflared/8e249ea0-1285-4a86-81fc-eb3733a16cf4.json:/etc/cloudflared/cred.json:ro
    networks: [edge]
    depends_on:
      ezagent:
        condition: service_healthy
```

> `deploy.sh` 已含 stable profile(Task 6 的 `[ "$CHANNEL" = stable ] && CH+=(--profile stable)`),此处无需再改。

- [ ] **Step 2: cloudflared config(stable → ezagent-stable:10042;codex#14 保留 originRequest)**

```yaml
# docker/cloudflared/stable-config.yml — 从现有 prod-config.yml 迁移,保留 originRequest,
# 仅把 service 改为 edge 网上稳定可解析的 ezagent-stable:10042
tunnel: 8e249ea0-1285-4a86-81fc-eb3733a16cf4
credentials-file: /etc/cloudflared/cred.json
ingress:
  - hostname: app.ezagent.chat
    service: http://ezagent-stable:10042
    originRequest:
      connectTimeout: 30s
      tcpKeepAlive: 30s
  - service: http_status:404
```
> 落地前 `diff` 现有 `docker/cloudflared/prod-config.yml`,把它实际的 `originRequest.*` 逐项搬过来(以现网为准)。

- [ ] **Step 3: operator 造 beta/stable env(端口 10042/10043,独立 PG 密码)**

```bash
for c in beta stable; do cp docker/.env.channel.example docker/.env.$c; mkdir -p docker/secrets-$c/mihomo
  CK=$(openssl rand -hex 24)   # codex#10:EZAGENT_COOKIE == RELEASE_COOKIE,每环境一个独立值
  printf 'EZAGENT_COOKIE=%s\nRELEASE_COOKIE=%s\n' "$CK" "$CK" > docker/secrets-$c/ezagent.env; done
# 编辑: beta → CHANNEL=beta EZAGENT_IMAGE=ezagent:beta PUBLIC_HOST=beta.ezagent.chat HOST_ADMIN_PORT=10042 SECRETS_DIR=./secrets-beta
#       stable → CHANNEL=stable EZAGENT_IMAGE=ezagent:stable PUBLIC_HOST=app.ezagent.chat HOST_ADMIN_PORT=10043 SECRETS_DIR=./secrets-stable
# beta 的 DNS A 记录(同 Task5 Step3,name=beta → ts 容器 100.x);stable 的 app 记录已由现有 cloudflared 隧道托管
```

- [ ] **Step 4: 校验 stable profile 合法**

Run: `docker-compose --env-file docker/.env.stable -f docker/docker-compose.yml --profile stable config -q && echo OK`
Expected: `OK`(cloudflared 出现在渲染结果)。

- [ ] **Step 5: 端到端晋级实测(nightly→beta→stable,验证 build-once)**

```bash
SHA=$(git rev-parse --short main)
git branch -f beta "$SHA" && git push origin beta        # 触发 workflow → deploy.sh beta(应 re-tag,不重编)
# 等 Actions 绿后:
git branch -f release beta && git tag v0.1.0 release && git push origin release v0.1.0  # 版本固定 0.1.0
docker images ezagent --format '{{.Repository}}:{{.Tag}} {{.ID}}'
ID_SHA=$(docker image inspect "ezagent:${SHA}" --format '{{.Id}}')
ID_BETA=$(docker image inspect ezagent:beta --format '{{.Id}}')
ID_STABLE=$(docker image inspect ezagent:stable --format '{{.Id}}')
[ "$ID_SHA" = "$ID_BETA" ] && [ "$ID_BETA" = "$ID_STABLE" ] && echo "PROMOTE-INVARIANT OK" || echo "FAIL"
```
Expected: `PROMOTE-INVARIANT OK` —— 即 **`ezagent:<sha>` == `:beta` == `:stable` 同 image ID**(证明 build-once / 晋级逐字节相同)。
> 注:`:nightly` **可能不同 ID**——若 `main` 在本次 promotion 的 `<sha>` 之后又有合并,nightly 已指向更新的镜像。这是正常的,不纳入断言(advisor)。

- [ ] **Step 6: Commit**

```bash
git add docker/docker-compose.yml docker/cloudflared/stable-config.yml docker/deploy.sh
git commit -m "feat(deploy): beta + stable stacks (cloudflared profile for stable)"
```

---

## Milestone D — 备份 + 运维加固

### Task 10: `backup.sh <channel>`(pg_dump + 精选 FS 快照)

**Files:**
- Create: `docker/backup.sh`
- Create: `docker/com.ezagent.backup.plist`(launchd)

**Interfaces:**
- Produces:`./backups/<channel>/<ts>/{db.sql.gz, fs-snapshot.tar.gz, manifest.json}`。

- [ ] **Step 1: 写 backup.sh**

```bash
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
HOME_VOL=$(docker inspect "$("${CH[@]}" ps -q ezagent)" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
RUN_IMG=$(docker inspect "$("${CH[@]}" ps -q ezagent)" --format '{{.Image}}')
GIT_SHA=$(git rev-parse HEAD)
DB_START=$(date -u +%Y%m%dT%H%M%SZ)

# 域1: Postgres — 逻辑 dump(一致)
docker exec "$PG_CTR" pg_dump -U ezagent -d "ezagent_${CHANNEL}" | gzip > "$OUT/db.sql.gz"
DB_END=$(date -u +%Y%m%dT%H%M%SZ)

# 域2: Agent FS — 精选快照(跳过 node_modules / _build / deps)
docker run --rm -v "${HOME_VOL}:/src:ro" -v "$PWD/$OUT:/dst" alpine \
  tar czf /dst/fs-snapshot.tar.gz \
    --exclude='*/node_modules' --exclude='*/_build' --exclude='*/deps' -C /src .

# manifest:记录真实可恢复锚点(codex#13)。非原子快照(无 quiesce/LSN)明确标注。
cat > "$OUT/manifest.json" <<JSON
{"channel":"${CHANNEL}","ts":"${TS}","git_sha":"${GIT_SHA}","running_image":"${RUN_IMG}",
 "image_tag":"${EZAGENT_IMAGE}","home_volume":"${HOME_VOL}","pg_dump_start":"${DB_START}",
 "pg_dump_end":"${DB_END}","db":"db.sql.gz","fs":"fs-snapshot.tar.gz","atomic":false,
 "note":"per-domain logical backup; DB and FS NOT a single consistent snapshot"}
JSON
echo "backup done: $OUT"
```

- [ ] **Step 2: 校验 + 实跑 nightly**

Run: `bash -n docker/backup.sh && chmod +x docker/backup.sh && docker/backup.sh nightly && ls -la backups/nightly/*/`
Expected: 见 `db.sql.gz`(非空)、`fs-snapshot.tar.gz`、`manifest.json`。

- [ ] **Step 3: launchd 定时(每日 04:00,nightly+beta+stable)**

> codex#15:plist **不硬编码开发 worktree**。`.example` 模板用占位符 `__DEPLOY_DIR__`,operator 用安装脚本
> 渲染成**部署最终 checkout 的绝对路径**(self-hosted runner 的 `_work/ezagent/ezagent`,或你固定的部署目录)。

```xml
<!-- docker/com.ezagent.backup.plist.example → 渲染 __DEPLOY_DIR__ 后装到 ~/Library/LaunchAgents/ -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ezagent.backup</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>-lc</string>
    <string>cd __DEPLOY_DIR__ &amp;&amp; for c in nightly beta stable; do docker/backup.sh $c; done</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardErrorPath</key><string>/tmp/ezagent-backup.err</string>
  <key>StandardOutPath</key><string>/tmp/ezagent-backup.out</string>
</dict></plist>
```
operator 装(渲染绝对路径):
```bash
DEPLOY_DIR=$(pwd)   # 在最终部署 checkout 里执行
sed "s#__DEPLOY_DIR__#${DEPLOY_DIR}#" docker/com.ezagent.backup.plist.example > ~/Library/LaunchAgents/com.ezagent.backup.plist
launchctl load ~/Library/LaunchAgents/com.ezagent.backup.plist
```

- [ ] **Step 4: Commit**

```bash
git add docker/backup.sh docker/com.ezagent.backup.plist
git commit -m "feat(deploy): per-channel logical backup (pg_dump + curated FS) + launchd"
```

---

### Task 11: Time Machine 排除 + OrbStack 自启(operator,记 runbook)

**Files:** 无代码;记入 runbook。

- [ ] **Step 1: 核对 OrbStack data 已排除 TM(默认即排除,无需 tmutil)**

```bash
orb config get data_allow_backup    # 期望 false → OrbStack 已把 data.img 排除出 TM
tmutil isexcluded "$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"   # 应 [Excluded]
```
Expected: `false`;路径 `[Excluded]`。**若 `data_allow_backup` 变成 true**(被人改过)→ `orb config set data_allow_backup false`。已查证本机默认 false,故通常只需核对。

- [ ] **Step 2: 确认 backups/ 在 TM 覆盖内(不排除)**

Run: `tmutil isexcluded "$PWD/backups"`
Expected: `[Included]`(逻辑备份要被 TM 备走)。

- [ ] **Step 3: OrbStack 随登录自启 + Mac 不休眠**

```bash
orb config get app.start_at_login    # 本机已 true
sudo pmset -a sleep 0                 # 服务器常开,禁系统休眠(operator 确认电源策略)
```

- [ ] **Step 4: Commit runbook**

```bash
git add docs/guide/deploy-mac-stack.md
git commit -m "docs(deploy): TM exclusion + OrbStack autostart runbook"
```

---

## Milestone E — 文档收口

### Task 12: 升级 `docs/guide/deploy-mac-stack.md` 为三环境 runbook

**Files:**
- Modify: `docs/guide/deploy-mac-stack.md`

- [ ] **Step 1: 重写指南结构**

章节:① 三环境架构图(nightly/beta/stable + 共享 infra + 两层网络)② 命名/通道/分支晋级 ③ 一次性 operator setup(汇总 Task 5/7/11 的实跑命令)④ 日常:晋级(`git branch -f …`)、回滚、查状态 ⑤ 备份与恢复(`backup.sh` + `pg_restore` + FS 回放;TM 分层)⑥ 故障排查。

- [ ] **Step 2: 删除被取代的旧 compose**

```bash
git rm docker/docker-compose.prod.yml docker/cloudflared/prod-config.yml
# 在指南里注明:prod-config 内容已迁入 stable-config.yml
```

- [ ] **Step 3: 全量静态校验(三通道 config 均绿)**

Run(channel 与 infra 分开校验 —— 不合并,codex 致命#1):
```bash
JMS_SUBSCRIPTION_URL=x CF_API_TOKEN=x TS_AUTHKEY=x docker-compose --env-file docker/.env.infra -f docker/docker-compose.infra.yml config -q && echo "infra OK"
for c in nightly beta stable; do
  P=""; [ "$c" = stable ] && P="--profile stable"
  docker-compose --env-file docker/.env.$c -f docker/docker-compose.yml $P config -q && echo "$c OK"
done
```
Expected: `infra OK` / `nightly OK` / `beta OK` / `stable OK`。

- [ ] **Step 4: Commit**

```bash
git add docs/guide/deploy-mac-stack.md
git commit -m "docs(deploy): three-env runbook; drop single-env prod compose"
```

---

## Self-Review

**Spec coverage(对 spec 逐节核对):**
- §1 命名/通道 → Task 2(env)、Task 4/9(域名)、Task 6(image tag)✅
- §2 分支/晋级 → Task 9 Step5(`git branch -f` + tag + build-once 验证)✅
- §3 CI/CD → Task 6(deploy.sh)、Task 7(runner)、Task 8(deploy.yml,nightly cron + push;只对已绿制品跑健康/smoke)✅
- §4 拓扑 → Task 1(compose project 隔离 + 两层网络 + 端口)、Task 2(secrets 分环境)、Task 3(共享 mihomo/Caddy)✅
- §4.3 接入 → Task 3(tailscale sidecar + Caddy `network_mode: service:tailscale`)、Task 4/5(Caddy DNS-01 + ts 100.x + DNS A)、Task 9(cloudflared stable)✅
- §5 存储/备份 → Task 1(named volume)、Task 10(双域逻辑备份)、Task 11(核对 OrbStack `data_allow_backup:false` 已排除 TM)✅
- §6 OrbStack → Task 11(autostart)、Task 4(Caddy 自编镜像绕 OrbStack 无关坑)✅
- §7 回滚 → Task 6(deploy.sh 回滚)、Task 12(数据恢复文档)✅
- §9 验证 DoD → Task 5/9 的可达性 + image-ID 一致性实测 ✅

**Placeholder scan:** 无 TBD/TODO 占位;smoke.sh 给的是真实最小脚本(Task 8 Step2),注明随 VERIFICATION.md 扩充——非占位。

**Type/命名一致性:** 通道名 `nightly/beta/stable`、image `ezagent:<sha>`/`ezagent:<channel>`、edge 网 `ezagent_edge`、别名 `ezagent-<channel>`、卷 `ezagent-<channel>_{home,pg}` 全计划统一。

---

## Execution Handoff

> 待 writing-plans 流程提示选择执行方式。
