# Deploy Flow Design — 三环境晋级阶梯(nightly / beta / stable)

> Status: **Design (approved in brainstorm 2026-06-25)** — 待 Allen 复核后进 writing-plans。
> Scope: 在**一台 Mac**(OrbStack)上跑三个 ezagent 环境,形成 `nightly → beta → stable`
> 的发布通道阶梯;定义分支模型、CI/CD 触发、部署拓扑、存储与备份。
> 基础事实来自:#942(已落 main 的全容器化 Mac stack)、#941(CF Containers 成本/选型分析,
> 选定 Mac+tunnel 为 alpha 目标)、`docs/guide/deploy-mac-stack.md`(现行单环境部署指南)。

---

## 0. 背景与目标

#942 已经把"stay-on-Mac"单环境(prod)全容器化:`ezagent`(BEAM+agents)+ `postgres` +
`mihomo`(出口代理)+ `cloudflared`(隧道),并在 Mac 上跑通全部 runtime gate。

本设计把它从**单环境**扩展为**三环境发布通道阶梯**,目标:

- **nightly** —— 每晚从主干自动构建,验证功能开发,仅 tailnet 可访问。
- **beta** —— 从 nightly 晋级,功能完整性冒烟门禁,仅 tailnet 可访问。
- **stable** —— 从 beta 晋级,生产,公网可访问。

核心原则:**build once, promote the artifact**(构建一次,晋级同一制品),三环境部署的镜像逐字节相同。

非目标(本期不做,留 TODO):
- 邮件架构改造 —— **保持现状**(现有 `ezagent-cf-token` 下的 `ezagent-email-inbox` worker:
  CF Email Routing → KV → pull),这样三环境部署后即带"程序化收/发邮件"能力。
  人类信箱(企业微信)、per-user `username@<mail-subdomain>` external-mirror、出站 relay 等
  另起设计(见 §10)。

---

## 1. 命名与通道

采用 Rust/Mozilla 风格的发布通道命名,**一个词从"环境名 = 域名 = git ref = docker tag"贯穿到底**:

| 通道 | 域名 | 接入 | git | docker tag | 构建方式 |
|---|---|---|---|---|---|
| **nightly** | `nightly.ezagent.chat` | Caddy(Headscale 100.x) | `main` HEAD(无独立 ref) | `:nightly` | cron 每晚 build `main` |
| **beta** | `beta.ezagent.chat` | Caddy(Headscale 100.x) | `beta` 分支 ref | `:beta` | **re-tag** nightly 的镜像(不重编) |
| **stable** | `app.ezagent.chat`(对外名) | cloudflared(公网) | `release` ref + `vX.Y.Z` tag | `:stable` | **re-tag** beta 的镜像(不重编) |

> 对外域名 `app.ezagent.chat` 保留好记的名字,内部通道/tag 叫 `stable` —— 对外名与内部通道名分开是常见合理做法。

---

## 2. 分支模型与晋级(promotion)

### 2.1 主干不反转 —— trunk-based CD

`main` 是**唯一长期主干**(= 日常 dev-together 合并目标,`ci.yml` 已门禁)。三通道**不是并行开发的独立分支**,
而是指向 `main` **线性历史**的"指针/书签",**只快进、永不分叉、零 back-merge**:

```
 dev-together per-task 分支 ──PR+CI门禁──▶  main   ← 唯一主干(活跃线)
                                            │
                                   每晚定时构建(nightly)
                                            ▼
                                    nightly 环境  ← 部署 main 当晚 SHA
                                            │ 验证 OK → 手动晋级
                                            ▼
                                     beta 环境  ← re-tag 同一镜像(beta ref)
                                            │ smoke e2e 绿 → 手动晋级 + 打 vX.Y.Z
                                            ▼
                                    stable 环境  ← re-tag 同一镜像(release ref + tag)
```

> 决策依据:反转主干(让 `main` 下游 pull `dev`)= 老式 GitFlow,需改 `ci.yml`/dev-together/全部文档,
> 风险大收益零。保持 `main` 为主干符合 trunk-based CD best practice 和仓库现状。

### 2.2 ref 与 tag 分工

| | 角色 | 可变性 | 用途 |
|---|---|---|---|
| **分支 ref**(`beta`/`release`) | "环境**现在**在哪个 SHA" | 可变(晋级前移) | 部署"该 ref 的 tip";一眼看各环境现状 |
| **版本 tag**(`vX.Y.Z`) | "该 commit **曾**作为 vX.Y.Z 发布" | 不可变 | 审计、回滚锚点、changelog |

- **nightly**:不需要 ref 也不需要 tag —— nightly cron 直接 build `main` HEAD(临时构建)。
- **beta**:`beta` 分支 ref;不打 tag(临时)。
- **stable**:`release` 分支 ref(指当前线上)+ 每次发布打不可变 `vX.Y.Z` tag。

### 2.3 晋级 / 回滚命令

```bash
# nightly → beta(beta 部署同一个测过的镜像,不重编)
git branch -f beta <nightly-sha> && git push origin beta          # 快进,无需 -f
# beta → stable(打版本号,stable 部署)
git branch -f release beta && git tag v0.2.0 release && git push origin release v0.2.0
# 回滚 stable 到上一个已知好 SHA
git branch -f release <prev-sha> && git push -f origin release     # 回退才 force
```

> 正常晋级是快进(无需 `-f`);回滚是后退(`-f`)。git ref/tag 与 docker tag 一一对应,
> 晋级 = 给同一 SHA 的镜像 re-tag。

---

## 3. CI/CD 触发

### 3.1 现有门禁不动

`ci.yml`(`mix precommit` + `check_invariants`,PR + push main)**保持不变**,继续把关进入 `main` 的代码。
因三通道只指向已过门禁的 main commit → **每个可部署 commit 天然是绿的**。

### 3.2 新增"部署触发" workflow —— self-hosted runner on Mac

Mac 在 Headscale 后面**无公网入站**,GH Actions 无法 SSH 进来 → 解法是**在 Mac 上装自托管 GH Actions runner**
(runner 主动 poll GitHub,无需开任何入站端口)。

触发器按通道**性质不同**:

| 通道 | 触发器 | 动作 |
|---|---|---|
| nightly | **`schedule:` 每晚 cron** | `build ezagent-prod:<sha>` → tag `:nightly` → 重启 nightly stack → 健康检查 |
| beta | **`push: branches:[beta]`** | **re-tag** `:beta`(不重编)→ 重启 beta stack → 跑 VERIFICATION.md 的 smoke e2e |
| stable | **`push: branches:[release]`** | re-tag `:stable` → 重启 stable stack → 健康检查 |

```yaml
# .github/workflows/deploy.yml(草案)
on:
  schedule: [{ cron: '0 19 * * *' }]   # 每晚(UTC,换算到本地)nightly
  push:
    branches: [beta, release]
jobs:
  deploy:
    runs-on: [self-hosted, macos, ezagent-deploy]
    # 按 github.ref / event 选通道 → build-or-retag → compose up 对应 stack → 健康检查 → 失败回滚
```

### 3.3 晋级门禁 —— 只对已绿制品跑健康/smoke

晋级时**不重跑 `mix precommit`**(main 合入时已绿)。各通道部署阶段只验:
- **健康检查**(容器 healthy、HTTP 起得来、迁移成功);
- **beta 额外跑** `docs/phase-specs/<phase>/VERIFICATION.md` 里对应的 smoke e2e flow。

配合 build-once/re-tag → **beta 测的镜像 = stable 跑的镜像(逐字节相同)**。

---

## 4. 部署拓扑

### 4.1 三 stack 隔离(compose project 自动命名空间)

三环境 = 三个 compose project,volume/network/容器全自动按 project 名隔离:

| | nightly | beta | stable |
|---|---|---|---|
| compose project | `ezagent-nightly` | `ezagent-beta` | `ezagent-stable` |
| volume | `…_home` + `…_pg`(named) | 同构 | 同构 |
| host admin 端口 | **10041**→10042 | **10042**→10042 | **10043**→10042 |
| secrets | `.env.nightly` + `secrets-nightly/` | `.env.beta` + … | `.env.stable` + … |
| Postgres | 独立容器 + 独立 `_pg` volume | 同左 | 同左 |
| 镜像 tag | `:nightly` | `:beta` | `:stable` |

- 容器内部端口固定 `10042`;host admin 三环境必须不同(同端口不能 bind 三次)→ `10041/10042/10043`,
  stable 保持现有 `10043`。
- 每环境**独立 Postgres 容器 + 独立 `_pg` volume** → 数据完全隔离。
- 每环境**独立 `.env` + 独立 `POSTGRES_PASSWORD`**。

### 4.2 共享 mihomo + Caddy,两层网络

`mihomo`(无状态出口代理)和 `Caddy`(nightly/beta 入口)**三环境共用**;为跨 compose project 互通,
网络分两层:

```
每环境私有网络(隔离):   ezagent ↔ postgres          ← PG 只在这,永不外露
共享 edge 网络(external): ezagent ↔ mihomo(出口,三环境共用一个)
                          Caddy ↔ ezagent(nightly/beta 入口,一个 Caddy 多 site-block)
                          cloudflared ↔ ezagent(stable 入口)
```

- 一个 **shared infra compose**(`ezagent-infra`)装共用 **mihomo + Caddy**;stable 的 `cloudflared`
  放 infra 或留在 stable stack(实现时定)。
- 每个 env stack attach 到 external edge 网络 + 自己的私有网络。
- 取舍:为共用 mihomo/Caddy,egress/ingress 这条线**故意打通**(非全隔离);但 **PG + 数据卷仍完全隔离**。

### 4.3 接入(承接 deploy-flow 早先决策)

- **nightly / beta**:**Caddy** 只监听 Headscale `100.x` 接口,用 **Cloudflare DNS-01 ACME**
  (复用 `ezagent-cf-token`)给 `nightly/beta.ezagent.chat` 签真 Let's Encrypt 证书(DNS 验证,无需公网端口)。
  CF DNS:`nightly`/`beta` 的 A 记录指向 Mac 的 `100.x` —— 公网解析到私网地址走不通,仅 tailnet 内可达。
  > 注:Headscale **不支持** `tailscale serve`/`tailscale cert`(issue #2527/#2137 仍 open),
  > 故走 Caddy 自签而非 Tailscale Serve。
- **stable**:`cloudflared` 隧道 → `app.ezagent.chat`(公网)。

---

## 5. 存储与备份

### 5.1 用 named volume(不用 bind mount)

理由:OrbStack 下 named volume(Linux 侧,近原生)仍最快;agent 工作目录是 `node_modules`/git checkout
等海量小文件,即便 OrbStack 把 bind mount 提到原生 75–95%,volume 仍更稳。**PG + agent FS 都用 named volume。**

### 5.2 两个状态域 —— 逐域逻辑备份(非 tar 数据目录)

| 域 | 存哪 | ✅ 备份做法 | ❌ 别做 |
|---|---|---|---|
| **Postgres** | `*_pg` volume | `pg_dump`/`pg_dumpall`(逻辑、一致、压缩),定时导到 `./backups/<env>/` | 运行时 tar PG 数据目录(不一致) |
| **Agent FS**(凭据/snapshot/日志 + agent 工作目录) | `*_home` volume | #941 精选快照:git SHA + 未提交 diff + `config_home`,**跳过 `node_modules`**;或 `docker run --rm -v …_home:/src -v ./backups/<env>:/dst alpine tar` | 把 `node_modules` 也备进去(大且可重建) |

**模式**:热数据在 volume(快),备份**写出到 host 文件夹** `./backups/<env>/`(顺序写大文件,OrbStack 无压力),
再交给离线层(Time Machine / R2)。

### 5.3 Time Machine 铁律(OrbStack 专属坑)

OrbStack 所有卷/镜像在单个 **8TB 稀疏文件 `data.img`**(`~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data`)。
TM 备份它会出事(显示 8TB → "no available space to restore";`data.img` 恢复困难;Migration Assistant 不支持稀疏文件)。

→ **铁律**:
1. 把 `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data` **从 Time Machine 排除**。
2. ezagent 状态保护**完全靠 §5.2 的逻辑备份 → `./backups/<env>/`**;Time Machine 只备份该 host 文件夹
   (在 `data.img` 之外,小而一致,可单文件恢复)。

---

## 6. OrbStack 注意事项

- **从 Docker Desktop 迁移**:旧 volume/镜像**不自动过来**;本期是 fresh 三环境部署,无影响,只需知晓
  现有 Docker Desktop 上 prod 数据(若有)不带过来。
- **开机自启**:stable 要长期在线 → 确保 OrbStack 随登录自启,Mac 保持登录/不休眠;`restart: unless-stopped`
  仅在 OrbStack 运行时生效。
- **bind mount 性能**:OrbStack 已把 bind mount 提到近原生 75–95%,若将来某处需要 bind mount,代价远小于
  Docker Desktop(但热数据仍用 volume)。

### 6.1 为何不用 Apple Container(决策留档,2026-06-25)

Apple `container` v1.0.0(2026-06-09)已成熟,但**对本用例不合适**,主因:
- **不支持 docker compose**(v1.0 仍缺,无官方时间表)—— 本设计三环境 + infra ≈ 15 容器全靠 compose 编排,这一条单独否决。
- **非 Docker API 兼容** —— 换它要推倒 #942 已落地的整套 Docker stack + 部署脚本。
- 每容器一独立 VM:隔离强但 ~15 VM 内存开销重。

本机为 macOS 26 Tahoe(`Darwin 25.x`),故 Apple Container 的"联网需 macOS 26"限制不构成障碍;
但**缺 compose 是致命伤**。→ **等 Apple Container 支持 compose 后再评估**。OrbStack(Docker 兼容 + compose 成熟 + 按需 RAM)为当前最优。

---

## 7. 回滚

- **代码层**:`git branch -f <ref> <prev-sha> && git push -f`(见 §2.3)→ runner re-tag 旧镜像 + 重启该 stack。
- **数据层**:从 `./backups/<env>/` 的逻辑备份恢复(`pg_restore` + FS 快照回放);跨域一致性按 #941
  的 quiesce → PG LSN + 快照 + manifest 绑定(本期可先做"各域独立恢复",一致性快照留迭代)。

---

## 8. 模块边界(便于 writing-plans 拆任务)

1. **CI/CD**:self-hosted runner 安装文档 + `.github/workflows/deploy.yml`(nightly cron + beta/release push)。
2. **compose 改造**:`docker-compose.<env>.yml` 或参数化 `COMPOSE_PROJECT_NAME` + `.env.<env>`;三 stack + infra stack。
3. **网络**:external edge 网络 + 每环境私有网络。
4. **接入**:Caddy(Headscale 100.x + CF DNS-01)site-blocks for nightly/beta;cloudflared for stable。
5. **备份**:`pg_dump` + 精选 FS 快照脚本 → `./backups/<env>/`;TM 排除 OrbStack data 目录的 setup 步骤。
6. **文档**:把 `docs/guide/deploy-mac-stack.md` 升级为三环境版(durable how-to)。

每个单元有清晰单一职责、明确接口、可独立验证。

---

## 9. 验证(DoD —— 可演示制品)

- `git push origin beta` → beta stack 在 Mac 上**用与 nightly 相同镜像**重启,`beta.ezagent.chat` 经 Headscale
  返回 200,smoke e2e 绿。
- `git tag v0.2.0 release && git push …` → stable stack 重启,`app.ezagent.chat` 公网 200。
- 三环境 `docker volume ls` 显示 6 个隔离卷(`ezagent-{nightly,beta,stable}_{home,pg}`)。
- `./backups/<env>/` 出现 `pg_dump` 输出 + FS 快照;OrbStack data 目录已在 TM 排除列表。
- 回滚:`git branch -f release <prev> && git push -f` → stable 切回旧镜像,200 不中断(或可接受短暂重启)。

---

## 10. TODO / 留待后续设计

- **邮件架构**(本期保持现状):人类信箱(企业微信,apex MX)+ per-user `username@<mail-subdomain>`
  external-mirror(CF Email Routing 子域 → Worker 收;出站需真 relay SES/Resend,CF `send_email` 仅限已验证目的地址)。
  域名分线:apex→企业微信、`app.`→Web、`mail.`→程序化邮件;DMARC 给 mail 子域独立 `_dmarc`。实现前用 Context7 核 CF 当前发送能力。
- **跨域一致性快照**(#941 quiesce + PG LSN + R2 snapshot + manifest)—— 本期先做各域独立备份。
- **off-Mac 迁移路径**(#941 §7 分波次迁移)—— 超出本期。

---

## 附:来源

- #942 全容器化 return:`docs/together/2026-06-24/returns/containerize-mac-stack.md`
- #941 成本/选型分析:`docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md`
- 现行部署指南:`docs/guide/deploy-mac-stack.md`
- Headscale serve 不支持:headscale#2527 / #2137
- OrbStack:fast-filesystem blog、docs/file-sharing、issue #220/#943(TM 8TB 稀疏文件)
