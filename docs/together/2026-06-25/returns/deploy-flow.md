# Return — Deploy flow: nightly/beta/stable 三环境晋级阶梯

> **Task:** deploy-flow(在一台 Mac/OrbStack 上把单环境 prod 扩成三环境发布通道阶梯 + CI/CD + 备份)
> **Branch:** `feat/deploy-flow`(off `main` @ `65e72f90`)
> **PR:** (见 §Merge request)
> **Dev:** Claude(agent,自驱 /goal)
> **returned_at:** 2026-06-25 (+0800)
> **deadline:** n/a(无 2026-06-25 dev-together `plan.md`)
> **deadline_status:** out_of_scope(用户直接发起的部署任务)
> **Spec/Plan:** `docs/superpowers/specs/2026-06-25-deploy-flow-design.md` / `docs/superpowers/plans/2026-06-25-deploy-flow.md`

## What's done

从 brainstorm → spec → plan → codex 对抗评审(15 findings 全修)→ 实施 → 实机验证,全程在 `feat/deploy-flow` 分支。

- **三环境全部在 Mac 上 live 且 healthy**:`ezagent-{nightly,beta,stable}` 各自 ezagent + postgres 容器 healthy;
  共享 infra `ezagent-infra`(mihomo healthy + caddy + tailscale)。
- **build once / promote artifact 验证通过**:`ezagent:8c6a369d`(构建)== `:nightly` == `:beta` == `:stable`,
  共享同一 image ID `sha256:04d58fcb…`。`deploy.sh` 端到端跑通(build→tag→force-recreate→**校验运行容器 image ID**→health→rollback)。
- **stable 公网入口可用**:`app.ezagent.chat` 经 stable stack 的 cloudflared(8e249ea0 tunnel)→ **HTTP 302**。
- **数据隔离**:6 个独立 named volume(`ezagent-{nightly,beta,stable}_{home,pg}`);每通道独立 Postgres + 独立 `POSTGRES_PASSWORD`;PG 仅在通道私有网。
- **迁移生效**:nightly PG 31 张表(`invocations`/`dlq`/`credential_grants` 等)。
- **CI/CD**:self-hosted runner `ezagent-mac` **online**(labels `self-hosted,macos,ezagent-deploy`);`.github/workflows/deploy.yml`(schedule nightly + push[beta,release],`permissions: contents:read`,per-channel environment)。
- **备份**:`backup.sh nightly` 产出 `db.sql.gz`(1908 行 SQL)+ `fs-snapshot.tar.gz` + `manifest.json`(git_sha + running_image digest + 时间戳 + `atomic:false`);OrbStack `data_allow_backup=false` 已核(TM 排除 8TB blob),`backups/` TM `[Included]`。
- **dev-together skill 守则**:`commands/close.md` + `SKILL.md` 标注 `beta`/`release` 为部署指针(push/close 不得误用为 task 分支)。
- **三环境 runbook**:`docs/guide/deploy-mac-stack.md` 升级,含全部 operator 步骤 + 实测 gotcha。

### 实测发现 / 设计修正(均已落 spec/plan/scripts)
- **tailscale sidecar**(用户建议)取代 host-utun 绑定:de-risk **通过**(OrbStack VM 内 kernel tailscale + `/dev/net/tun` 可用,容器达 `head.h2os.cloud`)。
- **OrbStack 用 `docker-compose`(连字符 v5.x)**,无 `docker compose` 插件子命令 → 全脚本改用 `docker-compose`。
- **OrbStack 拉取代理** `network_proxy=http://127.0.0.1:7896`(Docker Hub 墙);build 代理 `host.docker.internal:7897`。
- admin 端口绑 `127.0.0.1`(避开 host-utun 坑);`EZAGENT_COOKIE==RELEASE_COOKIE`(codex#10)。

## DoD §9 对账

| # | 条目 | 状态 | 证据 |
|---|---|---|---|
| ① | 三 stack live + DoD | **met(public)** / **blocked(tailnet)** | 三 stack healthy;promotion invariant 同 image ID;6 卷;`app.ezagent.chat` 公网 302。**nightly/beta tailnet 200 + DNS-01 证书 = 待 preauth key**(见 blocker) |
| ② | deploy.sh + runner online + deploy.yml | **met** | deploy.sh nightly 跑通;runner `ezagent-mac` online;deploy.yml committed |
| ③ | backup + data_allow_backup=false | **met** | backup 产出三件套 + 富 manifest;`orb config get data_allow_backup`=false |
| ④ | dev-together 反映 beta/release | **met** | close.md/SKILL.md 守则 |
| ⑤ | 三环境 runbook | **met** | `docs/guide/deploy-mac-stack.md` |
| ⑥ | 待合并 PR | **met** | 见 Merge request |
| ⑦ | return 报告 | **met** | 本文件 |

## ⛔ Blocker(唯一)—— Headscale preauth key(nightly/beta tailnet 入口)

**ingress 栈已实证可用**,只差 sidecar 用一个干净 key 加入 Headscale。完整诊断:

1. **sidecar de-risk PASSED**:tailscale 在 OrbStack VM 内 kernel 模式起(`/dev/net/tun` OK),达 `head.h2os.cloud`,生成 nodekey,发 RegisterReq。
2. **唯一失败 = key 损坏**:`failed to parse auth-key: hash length mismatch, expected 64 chars, got 65`(89 字符、7 个 `-` 段、尾随多余 `-` → 粘贴损坏)。crash-loop 又破坏了 caddy 共享 netns 的 DNS(`127.0.0.11:53 refused`)。
3. **host-bind 备选已探索并证明 ingress 栈正确**:临时把 Caddy 绑 host `100.64.0.27:443`(正常 netns)→ Caddy **成功签发 nightly+beta 的 Let's Encrypt 证书(DNS-01,CF token 可写 DNS)**,从 edge 网实测 `https://{nightly,beta}.ezagent.chat` → **HTTP 302 + `tls_verify=0`(证书有效)**,反代到 ezagent app 正常。
4. **但 host-bind 不可用**:本机有一个**用户自有的 host caddy(PID 1439,launchd,`~/.config/caddy/Caddyfile`)占着 `*:443`**,遮蔽了 `100.64.0.27:443` 的 docker 发布 → 经 host/utun 的连接被它 reset。**不能动它(用户的服务)。**
5. **结论:sidecar 是正确设计**(绑 sidecar 自己的 100.x:443,不碰 host :443,无冲突,且可从本机自验)。已 revert 回 sidecar。**只差干净 key。**

**Unblock(≈2 分钟)**:
```bash
ssh head.h2os.cloud headscale preauthkeys create --user 45 --reusable --expiration 24h
# → docker/secrets-prod/headscale_authkey + docker/.env.infra TS_AUTHKEY
docker-compose --env-file docker/.env.infra -f docker/docker-compose.infra.yml up -d   # sidecar 加入,caddy 共享其 netns
TS_IP=$(docker exec ezagent-infra-tailscale-1 tailscale ip -4 | head -1)               # sidecar 自己的 100.x
# 把 nightly/beta 的 CF A 记录改指 $TS_IP(现指 host 100.64.0.27,需更新)
# 从本机 curl https://nightly.ezagent.chat/ → 200/302(走 sidecar IP,不经 host :443)
```
runbook §3 有完整步骤。

> **替代方案 B 已评估为 invasive(不推荐)**:本机 host caddy(`~/.config/caddy/Caddyfile`)用 **alidns**
> 服务 `*.inside.h2os.cloud`(zchat/hackforger/saneledger 等内网应用),**不含 cloudflare DNS 模块**。
> 要在它上面服务 `nightly/beta.ezagent.chat` 需:① 重建该 caddy 二进制加 CF 模块(动用户服务),或
> ② 改用 `*.inside.h2os.cloud`(偏离 goal 的 `.ezagent.chat` 域名)。两者都不干净。
> → **A(干净 preauth key → sidecar)是正解**:容器化 caddy 已带 CF 模块,在 sidecar 自己的 100.x:443 上
> 服务正确域名,不碰 host :443、不动用户 caddy。**唯一待办 = 干净 key。**

## Gate status

- 纯 infra 改动(无 `.ex` 应用代码)→ `mix` 门禁不适用。
- 静态:`bash -n` 三脚本 OK;`docker-compose config -q` infra + 三通道 OK(channel 需 secrets 在位)。
- 运行时:三 stack healthy + 公网 302 + 迁移 + 备份 + promotion invariant 全绿(见上)。

## Merge request

- **PR**:`feat/deploy-flow` → `main`(见 PR 链接;**待 Allen/lead 按 dev-together close 合并**,我不自合)。
- 改动全部 additive(docker/、.github/workflows/、docs/、.claude/skills/dev-together/、.gitignore);
  低冲突。`docker-compose.prod.yml` 保留为 superseded 蓝本(未删,降低风险)。
- **合并后的真实通道流程**:deploy.yml 与脚本须在 `main`/`beta`/`release` 上才能让 runner 自动跑;
  本次三环境是**本地实机验证**(直接 re-tag + compose up,等价 runner 在 checkout 后的动作)。合并后:
  `git branch -f beta <main-sha> && git push` 即触发 runner 真实晋级。

## Leftovers / 后续

- **tailscale preauth key**(上方 blocker)—— 唯一待 operator 动作。
- GitHub branch protection(beta/release)+ Environments(stable required reviewers)—— 见 runbook §2E,建议合并后配。
- launchd 备份 plist —— 渲染绝对路径安装(runbook §2F);本次未在最终部署目录安装(worktree 验证为主)。
- 邮件架构改造 —— spec §10 deferred(保持现状 CF Email Routing→KV→pull)。
- 跨域一致性快照(quiesce+LSN)—— 迭代项。
