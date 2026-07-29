# Forgejo Provider V1 设计

> **日期：** 2026-07-29
> **基线：** `origin/main@c4ec7b478`（含 Git Provider V1 Plan E 全部成果 #1445 → #1614）
> **实证依据：** `docs/superpowers/specs/2026-07-29-forgejo-api-probe-findings.md`
> **继承设计：** `docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md`（下称 **Plan E**）
>
> 本文只写**与 Plan E 不同的部分**，以及相同部分为何相同。Plan E 未被本文
> 显式改写的条款**原样继承**，包括 §3.4 的授权决定、§5 的 durable model、
> §10 的 operator gate 与 §11 的完成声明边界。

---

## 1. 目标与范围

把 Plan E 已闭合的本地 provider-owned PR loop 扩展到第二个 provider：

```text
already-authorized task intake
→ durable accepted run
→ isolated task workspace
→ deterministic head branch
→ collect bounded text changes
→ Forgejo OAuth2 access token（1h，refresh 轮换，见 §4）
→ provider-owned Git commit
→ create-or-reconcile PR
→ fresh-read PR, statuses, reviews
→ persist confirmed provider-neutral facts
```

幂等目标与 Plan E §1 完全一致（同 run / 同 branch / 同 commit / 同 PR，
observation 只刷新 facts 不制造 mutation）。

**范围内：** 新 plugin `ezagent_plugin_forgejo` —— 既有的 5 个 adapter callback，
外加 OAuth2 凭证接入（§11 的 F0；2026-07-29 决定提前，见 §4.1）。
**范围外：** webhook 接入、merge action、canary、任何 workflow 侧改动。

**一个 adapter 同时服务 Forgejo 与 Gitea。** 版本串 `15.0.5+gitea-1.22.0` 直接内嵌
Gitea 版本，API 层至今兼容。但**必须做版本探测并记录**，不假设永远兼容（§13.3）。

---

## 2. 与 Plan E 的关系：复用矩阵

| 层 | 处置 | 依据 |
|---|---|---|
| `DomainGit.Adapter` 五个 callback | **完全复用，不新增不修改** | 契约本就 provider-neutral，这是它存在的意义 |
| `DomainGit` 值类型（`FileChange` / `ChangeRequest` / `Check` / `Review` / `CreateChangeRequest` / `Error`） | **完全复用** | 见 §8 的错误映射与 §9 的读路径映射，均落在既有封闭词表内 |
| `GitTaskAccess` policy / caps / dispatch | **完全复用** | 与 provider 无关 |
| workflow / StageRunner / Observation / facts / Blocker | **完全复用，一行不改** | P1–P4e 全部 |
| `AdapterRegistry` | 加一条 `{"forgejo", ForgejoAdapter}` 声明 | `AdapterDeclarationOwner`，形状照 `ezagent_plugin_github/application.ex:75-77` |
| `GitHubAdapter` 写路径 | **重写**（§7） | Git Data 写链在 Forgejo 上不存在 |
| `GitHubAdapter` 读路径 | **重写**（§9） | checks 模型不同（commit status 而非 Checks API） |
| `GitHubClient` | 形状可抄，**状态码语义与 base_url 必须重做**（§5.2、§8） | |
| `GitHubAppJwt` / `GitHubInstallation` / `InstallationPermissions` | **不适用，不移植** | Forgejo 无 App→installation 模型（§4） |

**workflow owner 零改动**是本设计的一条硬约束。任何需要改
`ezagent_plugin_git_workflow` 的发现都要停下来报告，不得顺手改。

---

## 3. 已冻结选择

### 3.1 Provider-owned commit 的 Forgejo 形状

Plan E §2.1 的 blob→tree→commit→ref 四步链**整条不可用**：Forgejo 的
`/git/blobs|trees|commits|refs` 全部只读（只有 GET）。替代路径：

```text
workspace changes
→ Ezagent.DomainGit.FileChange
→ DomainGit.Adapter.create_change_request/4
→ POST /branches（钉 base sha）+ POST /contents（批量文件）+ POST /pulls
```

与 Plan E §2.1 相同的部分：不把凭证注入 `git push`、credential helper、
Agent environment、task cwd 或 sidecar。

### 3.2 V1 change envelope

**与 Plan E §2.2 完全一致**，不放宽也不收紧：UTF-8 文本、仅 `:upsert`、
路径在已验证 task worktree 内、受 `ChangeLimits` 限制、无 symlink/submodule/
`.git/**`/删除/重命名/mode change/binary。

但 **`:upsert` 在 Forgejo 上没有单一对应操作**（§7.3），这是实现负担，
不是语义变化。

### 3.3 Human merge

**与 Plan E §2.3 完全一致**：V1 不新增 merge action，真实 merge 由 human/lead
在 Forgejo web 上执行。

### 3.4 确定性 commit（已实证保住）

Plan E §6.1 要求「重试产出同一个 commit sha」。**在 Forgejo 上成立，已实测**：

同 files / message / author / committer / dates、同 base，只改分支名的两次
独立调用产出逐字节相同的 `64c9857471e1ea9d30295c90fc0e58085377fa2b`
（findings §3.2）。

传递方式与 Plan E 一致：`CreateChangeRequest.commit_date` 必填无默认，
由 workflow 从 `git_workflow_runs.inserted_at` 填入，adapter 只使用不推导。
Forgejo 侧落到 `ChangeFilesOptions.dates.{author,committer}` +
显式 `author`/`committer` Identity，已实测经 `GET /git/commits` 权威读回相符。

---

## 4. 权限边界 —— 与 Plan E 的**实质**差异

### 4.1 认证模型（2026-07-29 实证订正）

**V1 采用 OAuth2 授权码流程，不是 PAT**（决定：gaga 2026-07-29）。

本节初稿把 PAT 与 OAuth2 并列成一档「帐号级、长期」。**实测推翻了「长期」**
（findings §8）：

| | GitHub（Plan E） | Forgejo **OAuth2** | Forgejo PAT |
|---|---|---|---|
| 模型 | App JWT → installation token | 授权码 + PKCE(S256) | 静态令牌 |
| access token 时效 | 1 小时 | **1 小时（`expires_in: 3600`，实测）** | 永不过期 |
| 续期 | 重新铸 | **refresh token，且每次轮换**（实测） | 无 |
| 粒度 | 每次操作一个最小权限 token | 类别级 `<read\|write>:<category>` | 同左 |
| 档位 | `InstallationPermissions.for!/1` 四档 | 无 | 无 |
| 作用域 | 精确到单仓库 | 见 §4.1.1 | 见 §4.1.1 |

Plan E §6.1 步骤 1「mint exact repository + `change_request_write` token」
在 Forgejo 上仍无对应物；但步骤 9「callback 返回前丢弃 token」照常成立，
且凭证**本身**已是短期的。

#### 4.1.1 per-repo 收窄拿不到 —— **已实证**（2026-07-29）

Forgejo 的 scope 词表形如 `<read|write>:<category>`（`repository` / `user` /
`issue` …），**语法里没有仓库选择器**，因此「只授一个仓库」无从表达。

**实测坐实**（findings §7.3）：一个以 `write:repository read:user` 授出的
OAuth token，`GET /user/repos` 返回该帐号下**全部**仓库，且 `permissions.push`
均为 `true`。

关键在时序 —— 第二个仓库是在**该 token 签发之后**创建的，token 照样看得见：

```
token 签发           ~17:xx
gagameow/ezagent-forgejo-test   created 16:14   ← 授权前已存在
gagameow/test-2                 created 18:02   ← 授权后才创建，仍可见
```

因此这个授权**不是签发时刻的仓库快照，而是持续跟随帐号**。
一个凭证的爆炸半径 = 该帐号在 `repository` 类别下的全部权限，
**与它是为哪个 binding 取得的无关**。

（保留一处未测：`permissions.push: true` 是服务端对该 token 的权限声明，
未做实际写入验证。结论不因此改变。）

#### 4.1.2 已实证的 scope 行为

- scope **按类别强制**，且拒绝时**点名缺哪个**：
  `token does not have at least one of required scope(s): [read:user]`；
- token 响应**不回显**已授予的 scope —— 拿不到「实际授予了什么」的回执，
  只能靠调用失败时的点名反推；
- 认证头 `Bearer` 与 `token` **两种写法都接受**（同一 OAuth token 打 `/user`
  均 200）。因此 `ForgejoClient` 现有的 `token` 方案对 PAT 与 OAuth 通用，
  **无需按凭证类型分支**。

#### 4.1.3 OAuth 应用只能由租户管理员在 web UI 注册

`POST /user/applications/oauth2` 存在，但实测需要 **`write:user`** scope——
那个 scope 能修改帐号设置，比仓库写权限更宽。**为省一次手工注册而让 Ezagent
常驻一个可改帐号的凭证，不划算。**

且它有先有鸡先有蛋问题：调这个 API 本身要一个已存在的凭证。

**结论：每个 Forgejo 实例由该租户的管理员在 web UI 注册一次 OAuth 应用**，
`client_id` / `client_secret` 录入 Ezagent。这是 per-instance 一次性成本，
摊给该实例下的整个用户群 —— 与 GitHub「一个 App 服务所有人」同形，
只是 Forgejo 自托管所以实例有 N 个。

### 4.2 保住什么，保不住什么

**保住 —— 凭证不出 plugin。** 与 GitHub 侧同构，且必须同等严格：

- 凭证只在 `ForgejoCredentialBackend` 与 `ForgejoClient` 之间流动；
- **每个 callback 从 credential backend 现取一次，用完丢弃，adapter 不缓存**；
- 不进入 `%AuthorizedTask{}`、不进入 workflow facts、不进入错误呈现、
  不进入 telemetry、不落日志；
- `ezagent_plugin_github/test/architecture/operation_scoped_credential_test.exs`
  的对应 gate 照搬。

> **口径说明：** GitHub 侧那条 gate 叫 "one token per callback"，语义是
> 「每 callback 铸一次」。Forgejo 侧没有铸造动作，语义收窄为
> 「**每 callback 现取一次、不跨 callback 复用、不缓存**」。
> **形状保留、强度下降**——测试名必须如实反映后者，不得沿用暗示铸造的名字。
> （交接文档 §6.1：一条名字承诺得比实际多的测试，比没有这条更糟。）

**短期 —— 走 OAuth 后保住了**（订正 2026-07-29）。access token 1 小时过期、
refresh 轮换，与 GitHub installation token 时效同级。本节初稿称「无自动过期」，
那是 PAT 的属性，被误当成 Forgejo 的属性。

**保不住 —— per-repo 最小权限。** 这是剩下的唯一实质差异：

- 一个凭证的爆炸半径是该帐号在 `repository` 类别下的全部权限，而非一个仓库
  一次操作（§4.1.1，结构性推断）；
- 无按操作降权（读路径的凭证同样持写权限）。

### 4.3 隔离单元 = 授权用户本人（2026-07-29 定，取代初稿的 bot 帐号方案）

初稿提议「每个 workspace 绑一个专用 bot 帐号」，并标为待人类拍板，理由是它把
安全属性从机制保证降级为运维约定。**改用 OAuth 后这个提议作废，问题也随之消解。**

每个用户**用自己的 Forgejo 帐号**走授权码流程，于是：

- 凭证的爆炸半径天然被**该用户本人已有的权限**封住 —— 系统无法授出用户自己
  没有的访问权，这是机制保证，不是运维约定；
- 不存在一个聚合了多人权限的共享 bot 帐号；
- commit 的 author/committer 是真实发起人，PR 归属清晰；
- `TaskBinding.credential_owner_uri` 已存在，正是承载「这条 binding 用谁的
  凭证」的字段，无需新设计。

因此**初稿那条「需要 gaga / Allen 拍板」的条目关闭**——不再需要引入运维约定。

### 4.4 授权层不变

Plan E §3.4 的两层分工（cap 层回答「是否合法框架内部流量」、`GitTaskAccess`
policy 层回答「这个 grantee 能否对这个仓库做这个动作」）**原样继承**。
Forgejo 不改变任何一层——provider 换了，业务授权没换。

§3.4.2 的全部约束（换 `compile_env` 缺省值而非 prod config、`Unavailable` 保留
为兜底、principal 取自持久化行、cap 五轴最小权限禁 `:any`、四条否定断言）
**继续适用**，无 Forgejo 特例。

---

## 5. 组件边界

### 5.1 新增：`ezagent_plugin_forgejo`

| 模块 | 职责 | 对照 |
|---|---|---|
| `ForgejoAdapter` | 5 个 callback；ref/commit/PR 的 create-or-reconcile；响应 → DomainGit typed values | `GitHubAdapter`（重写） |
| `ForgejoClient` | 薄 Req 封装；`Authorization: token <PAT>`；HTTP → 封闭错误码映射 | `GitHubClient`（形状可抄） |
| `ForgejoCredentialBackend` | PAT 存取，加密同 `GitHubTokenStore` 形状 | `GitHubCredentialBackend` |
| `Instance` | 每 binding 从 `provider_host` 推导 API base（见 §5.2；实现时由 `Config` 更名，`Config` 只留真正的应用配置） | — |
| `OAuthApp` | 每租户 OAuth 应用记录：`{workspace_uri, governed_host} → client_id + 加密 client_secret + redirect_uri`。**per-tenant 表，按不变式 14 必须 `workspace_uri NOT NULL`** | 无对应物（GitHub 全局一个 App，读 config 即可） |
| `ForgejoOAuth` | authorize URL / code 换 token / refresh。**端点按 `governed_host` 拼，不是模块常量** | `GitHubOAuth`（形状可抄，端点与 scope 处理不同） |
| `ForgejoDriver` | 8 个 `ProviderConnection.Driver` callback。**`refresh` / `reconcile_refresh` 有实义**（GitHub 侧无） | `GitHubDriver` |
| `ForgejoCallbackPlug` | OAuth 回调入口 | `GitHubCallbackPlug` |
| `Application` | 声明式注册 driver + backend pair + `{"forgejo", ForgejoAdapter}` | `ezagent_plugin_github/application.ex` |

**不移植：** `GitHubAppJwt`、`GitHubInstallation`、`InstallationPermissions`
（Forgejo 无 App→installation 模型）、`GitHubWebhookPlug`/`Verifier`（V1 无 webhook）。

#### 5.1.1 per-instance OAuth 装得进既有 domain（已查证，无需改 domain）

`provider_connections` 表已有 `workspace_uri` / `owner_uri` / `provider_id` /
**`governed_host`**，且 `governed_host` 在 `@immutable` 中——**连接身份本就是
「哪个租户的哪个用户、连到 provider X 的哪台主机」**。

driver 侧拿得到它：`local_authorization_backend/exchange.ex` 的 `invoke_driver/7`
把 `governed_host: row.governed_host` 放进 `private_frame`，driver 经 `exchange`
闭包读取（`GitHubDriver.begin_authorization/1` 正是这个形状）。

因此：**一个** Driver 声明 `{"forgejo", "oauth_user"}`，实例差异由 per-connection
的 `governed_host` 承载。§12 的「需要改 domain → 停止报告」**未触发**。

domain 未覆盖的只有 per-tenant 的 `client_id`/`client_secret`——它是 Forgejo
特有数据，由上表的 `OAuthApp` 归 plugin 自己存。

注册**必须走声明式 owner**（`Ezagent.DomainGit.AdapterDeclarationOwner`），
plugin 源码不得自己调 registry 的 register API——`:ezagent_plugin_check`
grep gate 会拒。

### 5.2 `base_url` 是 per-instance，不是常量

`GitHubClient` 硬编码 `@base_url "https://api.github.com"`。**Forgejo 不能这样**
——它是自托管的，每个 binding 指向不同实例。

`RepositoryRef.provider_host` 字段已存在，**base_url 从它推导**，不从 config
读全局常量。这一条直接影响多租户正确性：两个 binding 指向两个 Forgejo 实例时，
全局常量会把请求发错地方。

### 5.3 其余 owner 边界

Plan E §4.1（workflow owner）/ §4.2（workspace owner）/ §4.3（git domain）
**原样继承，零改动**。特别是 §4.3 的冻结：V1 不新增任何 adapter callback，
尤其不新增 merge action。

---

## 6. Durable model

**Plan E §5 全部原样继承，零改动。** run identity、deterministic branch 派生规则、
typed facts、state machine、单 SQL CAS 均与 provider 无关。

一条实证补充：`DeterministicRef.derive/2` 产出的 `task/p4e/run-<24hex>`
这类**带斜杠 ref 在 Forgejo 路径段上可用**（原始斜杠与 `%2F` 两种写法均正确
路由，findings §2.5）。曾担心它会一票否决整个设计，已排除。

---

## 7. Provider mutation reconciliation —— 核心重写

### 7.1 `create_change_request` 的 Forgejo 序列

一个 callback 内：

1. 从 credential backend 现取 PAT（§4.2）；
2. fresh-read base ref，验证 `expected_base_sha`；不符 → `:base_sha_mismatch`；
3. fresh-read deterministic head ref（`GET /branches/{ref}`）；
4. **分支不存在** → `POST /branches {new_branch_name: ref, old_ref_name: <expected_base_sha>}`
   - `201` → 分支已钉在 base，进 6
   - `409`（branch already exists）→ 并发创建竞态，回到 3 重读，**不当作失败**
5. **分支已存在** → 按其 head 分流：
   - `head == base` → 可安全写入，进 6
   - `head != base` → **绝不重发写请求**（§7.2）。读该 commit 逐字段比对：
     `parent == base` ∧ `message` ∧ `author`/`committer` 的 name/email/date
     ∧ 文件内容全等
     - 全等 → 是本 run 的产物，**跳过写入**，进 7
     - 任一不等 → `:head_ref_conflict`，fail closed，不 force push
6. 写入：`POST /contents`（`branch` = deterministic ref，**不带 `new_branch`**），
   带 `files` / `message` / `author` / `committer` / `dates`；files 的 create/update
   选择见 §7.3；
7. PR find-or-create（§7.4）；
8. 丢弃凭证。

### 7.2 为什么步骤 5 必须 read-before-write（实证）

`ChangeFilesOptions` **没有任何 parent / base_sha 字段**，父提交 = 服务端执行
那刻的分支头，隐式不可钉。实测后果（findings §3.3）：

> `operation: update` + 正确 blob sha + **内容逐字节相同** → `201`，
> 分支头 `64c98574` → `344f8c6e`。两个 commit 的 tree 逐条目完全相同。
> **同一棵树，两个 commit —— 纯空提交。**

所以 **`ChangeFileOperation.sha` 是 CAS 令牌，不是 no-op 守卫**。
任何「重试就重发写请求」的 adapter 会**每重试一次叠一个空 commit**。

确定性（§3.4）保证的是「同样的输入产出同样的 sha」，**不保证「重发操作无副作用」**
——这两件事在 GitHub 上被内容寻址合并了，在 Forgejo 上必须分开处理。

### 7.3 `:upsert` 的映射（每文件一次读）

Forgejo 无 upsert 语义，`create` 与 `update` 互斥且实测均 fail-closed：

| 请求 | 结果 |
|---|---|
| `create`，文件已存在 | `422 repository file already exists` |
| `update`，不带 `sha` | `422 a SHA or commit ID must be provided when updating a file` |
| `update` + 正确 `sha` | `201`（即使内容没变，也建新 commit） |

**方案（已选）：写前对每个路径在 head ref 上读一次**
（`GET /contents/{path}?ref=<head>`）：
- `404` → `operation: "create"`
- `200` → `operation: "update"` + 该响应的 `sha`

**未选：先试 `create`、422 再读 sha 转 update。** 往返次数相同（失败路径反而更多），
且把一个正常分支伪装成错误路径，错误映射表会被污染。

两种方案都存在 TOCTOU 窗口（读与写之间文件被改）。**兜底是步骤 6 的 422**：
读到的状态过期 → 重读一次 → 仍冲突则 `:head_ref_conflict` fail closed，
**不无限重试**。

### 7.4 PR find-or-create —— 不用专用端点

`GET /pulls` **没有 head/base 过滤**。存在 `GET /pulls/{base}/{head}`
（"Get a pull request by base and head"），但**它是陷阱，V1 不用**：
三次独立实测它一律返回**最老的、已 closed 的**那个 PR，而同 pair 的 open PR
存在（findings §2.2）。用它会把早已关闭的 PR 静默当作本 run 的 change request
返回——静默错误，比 fail closed 糟得多。

**采用：列表 + 客户端精确匹配**

```text
GET /repos/{o}/{r}/pulls?state=open&page=N&limit=50   （分页至尽）
→ 客户端精确筛 head.ref == deterministic_ref ∧ base.ref == base
→ 0 个   → POST /pulls 创建
→ 恰好 1 → 规范化返回
→ ≥2 个  → :change_request_conflict，fail closed
```

三条 Plan E 依赖的属性（只匹配 open / 零匹配则创建 / 多匹配则 fail closed）
全部保住。

**代价与保护：** 需遍历全部 open PR。分页**必须设上限**，超限仍未穷尽 →
返回错误而非截断后下结论（交接文档 §6.3）。对 bot 自有仓库 open PR 数有界。

### 7.5 Crash window 重排

Plan E §6.2 的五个窗口在 Forgejo 上**不是同一组**：

| Plan E 窗口 | Forgejo | 恢复 |
|---|---|---|
| commit 创建后、head 更新前 | **不存在** | `POST /contents` 建 commit 与推进分支是同一次调用，原子 |
| — | **新增：分支创建后、内容写入前** | 步骤 5 的 `head == base` 分支，正常继续 |
| — | **新增：内容写成功、响应丢失** ⚠️ | 步骤 5 的字段比对。**最危险的一个**——盲目重发会叠空 commit |
| head 更新后、PR 创建前 | 同形 | 步骤 7 的 find 分支 |
| PR 创建成功、fact 落库前 | 同形 | 步骤 7 的 find 分支 |
| facts 落库后、state CAS 前 | 同形，workflow 侧 | 不变 |
| observation 成功、snapshot 落库前 | 同形，workflow 侧 | 不变 |

恢复原则与 Plan E §6.2 一致：deterministic ref 是远端 mutation identity；
exact head+base 是 PR reconciliation identity；不用 PR title/body 作 identity；
不 force push；冲突 fail closed。

### 7.6 provenance 缺口：继承，不恶化

Plan E §6.2.1 记的缺口（deterministic ref 已存在但**仍停在 base** 时，adapter
分不清「自己上次留下的」与「外部 planted 的」）**在 Forgejo 上是同一条，不更严重**。

> **订正记录：** findings 文档首版（`fd690bcde`）曾据 schema 推断
> 「Forgejo 的 sha 相等性不再可依赖，缺口更严重」。实测推翻——commit sha 是
> `(parent, tree, message, author, committer, dates)` 的纯函数，可复现
> （findings §4）。**ref 已前进**时字段比对是充分判据；**ref 停在 base** 时
> 无 commit 可比对，这才是真缺口，与 GitHub 同源。

因此不为 Forgejo 单开议题，归 Plan E §6.2.1 同一条轨。
`plan_e_restart_reconciliation_test.exs` 那条 characterization 测试
（"a ref planted at base by someone else is resumed onto"）应有 Forgejo 对应版本，
**同样明确标注为未关闭**。

---

## 8. 错误与重试

### 8.1 HTTP → 封闭错误码映射

`Ezagent.DomainGit.Error` 是封闭类型，**不扩展**。Forgejo 特有状况全部落在既有词表：

| 来源 | 映射 |
|---|---|
| `401` | `:authentication_rejected` |
| `403` | `:repository_write_denied`（读路径 → `:repository_read_denied`） |
| `404` | `:repository_not_found` / `:base_ref_not_found`（按调用点语义） |
| `409` `POST /branches` "branch already exists" | **非错误**：并发竞态 → 重读分支（§7.1 步骤 4） |
| `422` `POST /contents` "branch already exists" | 同上语义，但**不同状态码**——见 §8.2 |
| `422` "repository file already exists" | 读到的状态过期 → 重读一次 → 仍冲突 `:head_ref_conflict` |
| `422` "a SHA or commit ID must be provided" | adapter 逻辑错误（该带 sha 没带）→ 不重试，`:invalid_file_change` |
| `413` quotaExceeded | `{:provider_request_failed, op, 413}` |
| `423` repoArchivedError | `:repository_write_denied` |
| `429` | `:provider_rate_limited` |
| 其它 | `{:provider_request_failed, op, status}` |

### 8.2 两个「已存在」用两个不同状态码（实测，易写混）

```
POST /branches   同名分支 → 409  "The branch already exists."
POST /contents   new_branch 撞已存在分支 → 422  "branch already exists [name: ...]"
```

**映射表必须按端点分别处理**，不能用一条通配规则。这是 findings §3.5 记录的
实测结果，不是推断。

### 8.3 传输失败 vs provider 5xx —— 本设计一并做对

交接文档 §8.2 记的既有缺陷：`GitHubClient` 把 `%Req.TransportError{}` 和
「其它 HTTP 状态」都映射成 `:provider_unavailable`，操作者分不出
「**你的网络断了**」与「**provider 挂了**」。

**本次探针撞上了真实案例**：一次 `POST /contents` 以 `curl (56) Failure when
receiving data` 失败，事后查证**服务端零副作用**（分支未建）。但如果它已在服务端
生效而响应丢失，恢复路径完全不同——这正是 §7.5 那个最危险窗口。

**决定：`ForgejoClient` 区分二者。** 传输层失败（连接失败/超时/响应截断）意味着
**远端状态未知**，必须走「重读远端再决定」；provider 5xx 意味着**请求已到达且被
拒绝**。

封闭 `Error` 类型无 `:provider_unreachable`。**不扩展类型**，用既有 catch-all
承载并保留可区分性：

```text
传输失败 → {:provider_request_failed, op, 0}    （status 0 = 未收到响应）
5xx      → {:provider_request_failed, op, status}
```

`0` 是「无 HTTP 状态」的显式记号。**该约定必须写进 `ForgejoClient` moduledoc
与 `Blocker` 呈现层**，否则 operator 看到 `status: 0` 会以为是 bug。

> 这条是否应回头统一到 `GitHubClient`：**属跨 owner 改动，本设计不做**，
> 记入 §13.1 待决。

### 8.4 Stable blockers 与 retry policy

Plan E §7.1 的词表与 §7.2 的分类**原样继承，不增不减**。Forgejo 未引入
任何 Plan E 词表覆盖不到的稳定失败类别。

---

## 9. 读路径映射 —— 两个实证发现改变了设计

### 9.1 `list_checks` 必须用合并端点

Forgejo 没有 GitHub 的 Checks API，只有**较老的 commit status 模型**：

```
GET /repos/{o}/{r}/commits/{ref}/statuses   全量历史
GET /repos/{o}/{r}/commits/{ref}/status     合并（CombinedStatus）
```

实测同一个 head sha（findings §6.1）：

| 端点 | 条数 | 每 context 是否唯一 |
|---|---|---|
| `/statuses` | **56** | 否——同一 context 最多重复 **7** 次 |
| `/status` | **17** | **是** |

`/statuses` 返回的是重跑历史。若用它，同一个 check 名字会产出 7 条
**结论互相矛盾**的 `Check` 记录，污染 §5.3 的 facts。

**采用 `/status`（合并端点），取 `statuses` 数组，每 context 一条最新。**

### 9.2 `CommitStatusState` → `Check` 映射

swagger 未枚举该类型（go 侧无约束 string），**从真实数据采样**得到
`pending` / `success` / `failure` / `skipped`（findings §6.2）：

| Forgejo | `Check.status` | `Check.conclusion` |
|---|---|---|
| `pending` | `:in_progress` | `nil` |
| `success` | `:completed` | `:succeeded` |
| `failure` | `:completed` | `:failed` |
| `skipped` | `:completed` | `:skipped` |
| `error` ⚠️ | `:completed` | `:failed` |
| `warning` ⚠️ | `:completed` | `:neutral` |
| 未知值 | `:completed` | `:other` |

⚠️ 标记的两个**未在采样中观察到**，取值来自 Gitea 状态词表的合理外推。
**实施时必须实测确认**，或至少保证未知值走 `:other` 而非崩溃。
`Check.external_id` 用 `CommitStatus.id`，`name` 用 `context`，`url` 用 `target_url`。

### 9.3 `list_reviews` 必须过滤 review **请求**

实测 `GET /pulls/{n}/reviews` 返回的 `state` 包含 **`REQUEST_REVIEW`**
（findings §6.3，采样于 Codeberg PR #13674 / #13659）——那是
「**向某人请求了 review**」，不是一条已提交的 review。

`DomainGit.Review.state` 的封闭词表是 `:approved | :changes_requested |
:commented | :dismissed`，**`REQUEST_REVIEW` 不属于任何一个**。

| Forgejo | `Review.state` |
|---|---|
| `APPROVED` | `:approved` |
| `REQUEST_CHANGES` ⚠️ | `:changes_requested` |
| `COMMENT` ⚠️ | `:commented` |
| `REQUEST_REVIEW` | **丢弃该条目**（不是 review） |
| `PENDING` ⚠️ | **丢弃该条目**（草稿，未提交） |
| 条目 `dismissed == true` | `:dismissed`（**取自布尔字段，不取自 state**） |

⚠️ 三个未在采样中观察到，实施时实测确认。

**`dismissed` 是与 `state` 并列的独立布尔字段**，不是一个 state 取值——
映射时先看 `dismissed`，再看 `state`。写反了会让被撤销的 approval 仍算作批准。

> Plan E §6.3「空 checks 或空 reviews 是有效事实，不得伪造成通过或批准」
> 在此尤其要紧：过滤掉 `REQUEST_REVIEW` 后**可能得到空列表**，那是正确结果。

---

## 10. 端到端验收

### 10.1 本地（Req.Test，不访问真实 Forgejo）

Plan E §8 的主场景与断言**原样继承**，仅替换 provider 交互：

```text
accept task → authorize test task → prepare workspace
→ test worker 写一个受限 UTF-8 文件 → collect FileChange
→ 取 PAT → POST /branches + POST /contents + PR find-or-create
→ read PR / statuses / reviews → persist normalized facts
```

重复完整执行两次，断言：一个 run / 一个 provision / 一个 deterministic ref /
**一个有效远端 commit** / 一个 PR / 第二次允许 fresh-read 但无重复 mutation /
凭证取用次数符合 callback 数且不出 plugin / facts 与 responses 一致。

**Forgejo 特有的故障注入（在 Plan E §8 八项之外新增）：**

1. **分支已前进、内容与本 run 全等** → 跳过写入，不叠 commit，返回同一 PR；
2. **分支已前进、内容不符** → `:head_ref_conflict`，零写入；
3. `POST /branches` 返回 `409` → 重读后正常继续，**不算失败**；
4. `POST /contents` 返回 `422 branch already exists` → 与 3 区分处理；
5. **传输失败（无 HTTP 状态）** → `{:provider_request_failed, op, 0}`，
   且恢复路径走重读而非重发（§8.3）；
6. `/statuses` 与 `/status` 混淆的回归防护：喂入同 context 多条历史，
   断言产出**每 context 一条**；
7. reviews 含 `REQUEST_REVIEW` → 被丢弃，不进 facts。

### 10.2 真实 E2E（打 `code.hyprial.com`）

骨架照搬 `github_live_case.ex`，包括**透传观察器**（`plugins:` 挂 Req request
step，请求飞向真实 provider **之前**抄一份 `{method, path}` 给测试进程；不拦截、
不伪造、不改写）。交接文档 §6.2：拿替身数请求，数的是替身的行为。

差异：

- **默认排除**，tag 用 `:live_forgejo`，照 `:live_github` / `:live_miro` 先例；
  不带 `--include` 时 CI 不受影响；
- **不需要代理** —— `code.hyprial.com` 本机直连可达（实测裸 curl 200）。
  交接文档 §5.3 那条 Req/Finch 代理配置在这条线上用不上；
- 凭证从 `forgejo-token.txt` 形状的本机文件读，**已入 `.git/info/exclude`**；
- `GitRunner` 的 `clear_env: true` 加固**不动**；若 live 测试需要真实仓库，
  照 `mirror_real_repo!/2` 的做法本地镜像。

覆盖 §8 中所有涉及 Forgejo 的部分。**刻意留在替身上的**：429/5xx 映射
（无法让 provider 按需故障）、digest 冲突 / CAS 竞态（纯本地）。

---

## 11. 实施切片

| 片 | 状态 | 交付 | 依赖 |
|---|---|---|---|
| **F1** 骨架 | **已完成**（`1e976fbc1`） | mix 项目；`Instance`（base_url 从 `provider_host` 推导）；`ForgejoClient`（认证头 + §8.1 映射 + §8.3 传输区分）；`ForgejoCredentialBackend` | 无 |
| **F0** OAuth 接入 | 待做 | `OAuthApp` 存储 + migration；`ForgejoOAuth`；`ForgejoDriver` 8 callback；`ForgejoCallbackPlug` + 路由；driver/backend-pair 声明；**把 `ForgejoCredentialBackend` 的两个 refresh callback 从 `:backend_unavailable` 换成真实现** | F1 |
| **F2** 读路径 | 待做 | `resolve_repository` / `read_change_request` / `list_checks`（§9.1-9.2）/ `list_reviews`（§9.3）。纯读，无 reconciliation | F0 |
| **F3** 写路径 | 待做 | `create_change_request` 全序列（§7.1）；read-before-write；upsert 映射；PR find-or-create；§10.1 全部故障注入 | F2 |
| **F4** 本地 E2E | 待做 | §10.1 主场景 + Plan E §8 八项 + Forgejo 七项 | F3 |
| **F5** 真实 E2E | 待做 | §10.2 | F4 |

**F0 编号在 F1 之后但排在 F2 之前**：F1 已经合入，而 F0 是 2026-07-29 决定
提前的（初稿把 OAuth 列为范围外，靠手工塞 PAT，会让 F2 无法端到端验证）。
保留 F1 原编号以免既有 commit 与文档交叉引用失效。

F0–F3 严格串行（F2 的凭证来自 F0，F3 的 reconciliation 依赖 F2 的读）。

**每片都不得修改 `ezagent_plugin_git_workflow` / `ezagent_domain_git` /
`ezagent_domain_workspace`。** 出现此需求 → 停止报告（§12）。

---

## 12. Lead review gates

Plan E §10 原样继承：worker 从 handoff 写死的 SHA 新开独立 branch + linked
worktree；不改 main worktree、不自行 merge main、不碰 canary。

顺序：`F1 → F2 → F3 → F4 → F5 → PR CI`。

**F3 须单独评审**——它是唯一含远端 mutation 与 crash-window 恢复的切片，
§10.1 的七条 Forgejo 故障注入必须**真的会红**（照交接文档 §6.1 的变异验证：
把被测机制换成 `do: :ok`，测试应当变红；不红说明测试是空转的）。

必须停止并报告的事项，在 Plan E §10 清单之上新增：

- 需要修改 workflow / domain_git / domain_workspace 任一 owner；
- 需要扩展 `DomainGit.Error` 封闭类型；
- 需要新增 adapter callback；
- **§4.3 的帐号级隔离未获人类确认**（这是 F1 之前就要闭合的前置）。

---

## 13. 未决 / 待人类决定

1. ~~**§4.3 帐号级隔离**~~ —— **已关闭**（2026-07-29）。改走 OAuth 后每个用户
   用自己的帐号授权，爆炸半径由用户本人已有权限封住，是机制保证而非运维约定，
   不再需要人类拍板。
2. ~~**§4.1.1 per-repo 收窄未实证**~~ —— **已关闭**（2026-07-29）。帐号新建第二个
   仓库后复测坐实：签发在前的 OAuth token 看得见创建在后的仓库，授权持续跟随
   帐号而非签发时快照。见 §4.1.1 与 findings §7.3。
3. **§8.3 是否回头统一 `GitHubClient` 的传输/5xx 区分** —— 跨 owner 改动，
   本设计不做，建议单独一片。
4. **`redirect_uri` 匹配规则**（精确 / 前缀 / 是否允许 http+localhost）未测。
   只影响给租户管理员的注册说明，不影响代码结构；F0 实施时顺带验。
5. **OAuth 请求哪些 scope** —— 已知需要 `repository` 类别的写权限；`read:user`
   用于识别授权者身份。token 响应**不回显**已授予 scope（§4.1.2），所以最终集合
   要靠 F2/F3 的真实调用反推：缺 scope 时 Forgejo 会点名。
6. **版本探测策略** —— 一个 adapter 服务 Forgejo + Gitea，探测到什么程度、
   不兼容时如何降级，本设计未定。建议先记录版本到 telemetry，不做行为分支。
7. **§9.2 / §9.3 的 ⚠️ 取值** —— `error` / `warning` / `REQUEST_CHANGES` /
   `COMMENT` / `PENDING` 未在采样中观察到，实施时实测确认；无论如何未知值
   必须走 `:other` / 丢弃，不得崩溃。
8. **§2.2 的 PR 端点行为待在目标实例复核** —— 现有结论采自 Codeberg
   16.0.0-dev，目标实例是 15.0.5。结论不变则 §7.4 直接落地；即使不同，
   §7.4 仍是安全选择。

---

## 14. 完成声明

本设计实施完成后可以声明：

> Forgejo provider V1 本地 provider-owned PR loop 当前切片完成；
> 若 F5 通过，可加「并已在真实 Forgejo 实例上验证」。

**不得声明**（继承 Plan E §11，逐条适用）：

- Git Provider E2E 生产闭环完成；
- production authorization 已接线；
- managed Agent canary 已完成；
- Forgejo merge loop 已完成；
- Kanban / socialware projection 已完成。

Plan E §10 的 operator gate **未解除**，Forgejo 线继承同样的边界。
