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
Gitea 版本，API 层至今兼容。但**必须做版本探测并记录**，不假设永远兼容（§13.6）。

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
（findings §7）：

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
  一次操作（§4.1.1，已实证）；
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

#### 5.1.0 唯一的 domain_git 改动：`OperationContext.credential_owner_uri`

adapter 要拿凭证必须先解析一条已存储的连接，而解析需要「用谁的凭证」。
`Entity.GitTaskAccess` policy 里本来就有 `credential_owner_uri`（与 `grantee_uri`
是两个不同角色：谁可调用 vs 用谁的凭证），但 ActionSet 构造 `OperationContext`
时没有往下传。

**决定（gaga 2026-07-29，codex 独立复核）：给 `OperationContext` 加这一个
provider-neutral 必填字段**，由 ActionSet 从 policy 填。

- 不违反 Plan E §4.3 的冻结 —— 那冻结的是 adapter **callback 集合**，不是
  DomainGit 值形状；`CreateChangeRequest.commit_date` 是同一先例。
- **不加 `execution_identity`**。它不是 provider 账号 ID（那是
  `external_account_id`），而是类别字符串；本 driver 恒产出 `"connected_user"`，
  由 adapter 自己供给即可，provider 侧概念不进中性类型。
- 必填无默认，理由同 `commit_date`：静默缺失会在很晚才表现为「凭证解析不出来」。
- 顺带补了它的 workspace 一致性校验 —— 原先跨 workspace 的凭证持有者会被接受。

**为什么不是「ActionSet 解析连接后把凭证句柄交给 adapter」**：那会让明文凭证
流经 domain 代码，违反 §4.2 的「凭证不出 plugin」；且会给 provider-neutral 的
Git domain 引入 provider-connection 的知识与依赖。

**泛化**：GitHub 才是特例（App 每次操作现铸），Forgejo / Gitea / GitLab / 各种
自托管都是「凭证是存下来的」，这个字段服务的是普遍情况。

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

### 7.6 provenance 判据：字段 + 内容（2026-07-30 加强）

> **加强记录（gaga 裁决，2026-07-30）：** 本节原表述为「**ref 已前进**时字段比对
> 是充分判据」。第二轮 review 指出字段全部派生自 run（message/身份/日期），所以
> 同一 run 的两次尝试若产出**不同 file_changes**，字段会全部巧合 → 第二次被判
> `:already_written` → 跳过写入 → 开出指向第一次内容的 PR。
>
> 调研结论支持加强：**我们自己的 GitHub adapter 一直在比对 tree**
> （`github_adapter.ex:298`，注释原文 "Parent equality alone does not distinguish
> this run's commit from any other commit that happens to share the same base"）。
> 它能这么做是因为 GitHub 的 blob/tree 创建内容寻址且幂等，重建即可拿到 sha。
>
> Forgejo 无 Git Data 写链（findings §1），但**实测坐实 `/contents` 返回的 `sha`
> 就是标准 git blob sha**（`sha1("blob <len>\0" <> bytes)`，逐字节验证一致）。
> 所以「本次会写成什么」可**纯本地算出**，零请求。
>
> 因此判据加为：字段全等 **且** 每个改动文件在 head 上的 blob sha 等于本地算出的
> 期望值。首次执行路径零新增请求（`file_operations/2` 本就要读这些路径）；仅恢复
> 路径新增 N 次 GET（N = 改动文件数）。
>
> 未走「递归读全树 + 本地实现 git tree hashing」（方案 C）：那是唯一能做到 exact
> 的路，但要自己实现 mode 位、条目排序、子模块规则 —— 一个 bug 会把**所有**恢复判成
> 冲突。残留见 §12.4。

### 7.6.1 原缺口记录：继承，不恶化

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
- **需要代理，且必须显式传**（订正 2026-07-29，见下）；
- 凭证从 `forgejo-token.txt` 形状的本机文件读，**已入 `.git/info/exclude`**；
- `GitRunner` 的 `clear_env: true` 加固**不动**；若 live 测试需要真实仓库，
  照 `mirror_real_repo!/2` 的做法本地镜像。

覆盖 §8 中所有涉及 Forgejo 的部分。**刻意留在替身上的**：429/5xx 映射
（无法让 provider 按需故障）、digest 冲突 / CAS 竞态（纯本地）。

#### 10.2.1 订正：本机**不是**直连可达（2026-07-29）

本节初稿写「不需要代理，`code.hyprial.com` 本机直连可达（实测裸 curl 200）」。
**该结论错误。**

shell 环境本来就导出了 `https_proxy=http://127.0.0.1:7890`，curl **静默遵循**它。
所以那个「裸 curl 200」实际上是走代理的 200，我把它读成了直连。显式区分后：

```
curl --noproxy '*'            → Connection timed out after 25s
curl -x http://127.0.0.1:7890 → 200 in 1.5s
```

而 Req/Finch **不读** `https_proxy`（交接文档 §5.3），所以必须显式传
`connect_options: [proxy: {:http, host, port, []}]` —— 与 GitHub 那条线**完全相同**
的安排，不是「这条线用不上」。不传的症状是 `%Req.TransportError{reason: :timeout}`，
经本 adapter 报成 `{:provider_request_failed, op, 0}`。

这正是交接文档 §6.3 那条「别从截断/失败的操作下结论」的又一个实例：我从一个
悄悄用了代理的 curl 得出了直连可行，且从未用 `--noproxy` 验证过。

---

## 11. 实施切片

| 片 | 状态 | 交付 |
|---|---|---|
| **F1** 骨架 | ✅ `1e976fbc1` | `Instance` / `ForgejoClient` / `ForgejoCredentialBackend` |
| **F0** OAuth 接入 | ✅ `6aaa59c07` `bdca9f550` `503199618` `70ae29fb2` | `OAuthApp` + migration、`ForgejoOAuth`、`ForgejoDriver` 8 callback、callback plug + 路由、声明、**凭证续期** |
| **F2** 读路径 | ✅ `89f0eb891` `eda2d0599` | `Normalize`、`CredentialSource`、四个读 callback、adapter 注册 |
| **F3** 写路径 | ✅ `8375646dc` | `create_change_request` create-or-reconcile + crash window |
| **F4** 本地 E2E | ✅ `e3705f21c` | 有状态实例桩 + 双次/三次执行幂等 + crash window |
| **F5** 真实 E2E | ✅ `082f2ee9d` | 打 `code.hyprial.com` 跑通（1 test / 14.7s） |

另有一处 domain_git 改动：`52acb50da`（`OperationContext.credential_owner_uri`，
见 §5.1.0）。全程 `mix ci.fast` EXIT=0，plugin 套件 188 tests / 0 failures。

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

## 12.1 凭证持久化 —— 已关闭（2026-07-30）

原限制：**凭证只存在 ETS，进程或 VM 重启后全部消失**，而 `provider_connections`
行是 durable 的，仍带着 `credential_backend_ref` / `credential_version`，重启后
留下一批「看起来 active」却指向不存在凭证的连接。

当时判断「GitHub 后端同样性质，所以是既有模式，统一修」。**这个判断被推翻了**，
因为两家的丢失代价不对等：

| | GitHub | Forgejo |
|---|---|---|
| 存的是什么 | user-to-server token，**仅用于识别身份** | **就是仓库凭证本身** |
| 仓库权限来自 | 每次操作用 config 里的私钥现签 installation token | 存着的这个 access token |
| ETS 被清的代价 | 身份关联丢失，可重建 | 每个用户每个实例**重走一次浏览器授权** |
| refresh token | 无（不需要） | 在同一条被清掉的记录里 |

所以「统一修」会把一个真实事故（Forgejo）压在一个可恢复瑕疵（GitHub）的节奏上。
Forgejo 侧单独修，GitHub 侧**故意保留 ETS**。

### 现在的形态

- `forgejo_credentials`（per-tenant 表）+ `EzagentPluginForgejo.CredentialRecord`
- 由 `Ezagent.ProviderConnection.SealedEnvelope` 密封 —— provider-connection
  domain 自己的带密钥、可轮转的信封，不是第三份私有 AES 实现。该模块本身是从
  domain 内**两份并行副本**（`exchange.ex` / `reconciliation.ex`）提取的
- `credential_ref` 绑进 AAD：密文搬到另一行打不开
- 版本 CAS 写在 WHERE 子句，并发替换的败者拿 `:stale_version`
- **handoff vault 仍在 ETS，是故意的**：那是操作内产物，丢了只是失败一次 refresh
  而 domain 会重试；凭证丢了才是重走授权
- 顺带修掉 `forgejo_oauth_apps` 缺 `key_id` 的问题 —— 它原来的信封没有密钥身份，
  换密钥就会让所有已存 client secret 打不开。现在与凭证同一个信封
- 删掉 `EzagentPluginForgejo.Sealed` 与 plugin 私有的 `token_encryption_key`：
  只剩一个 keyring

### 承重的验证

- `Backend.store` → 杀掉 backend 进程 → `Backend.lease_for_operation` 仍拿到原
  token。测试里先往进程私有 ETS 塞探针，杀完后断言探针消失 —— 否则这条测试
  证明不了任何东西（可能杀了个空进程）
- 变异验证：去掉 CAS 的版本条件、去掉 AAD 的 ref 绑定，各杀死一条测试
- 真实实例 E2E 连跑 3 次通过

---

## 12.2 Codex 对抗性 review 的六条缺陷（2026-07-30，全部已修）

外部 review 按 `origin/main...HEAD` 全量审。六条确认缺陷 + 一条怀疑，全部核实属实
并修复；怀疑那条经 swagger 实测后升级为确认。

### 高严重度

**① `ours?/2` 是 fail-open，注释与实现不符**（`forgejo_adapter.ex`）

注释声称按 `(parent, tree, message, author, committer, dates)` 判定，代码只比了
`message`。change request 标题是公开的，任何人都能写一个带该 message 的 commit →
被判为 `:already_written` → 跳过写入 → 开出指向**别人内容**的 PR。

修：比较 `write_contents/3` 钉下的**每一个**字段（message + author + committer +
两个 date）。`parents` 拿不到 —— branch 端点的 commit 对象只有
`{id, message, timestamp, author, committer, url, verification}`（实测），所以由
秒级精度的 date 承担主要区分力。时间戳按**时刻**比较而非字符串：Forgejo 用实例本地
偏移回显（实测 `+08:00`），字节比较会让自己写的 commit 也认不出来。

此前的变异测试没抓住它，因为那条测试的外来 commit 用了**不同的 message**。stub 也
只记录 `id`+`message`，根本无法表达"标题相同、其余不同"的 commit —— 已一并补全为
真实响应形状。

**② PR 查找只读第一页**

`GET /pulls` 无 head/base 过滤（findings §2.1），匹配在客户端做，所以必须读全。
停在第一页会把"PR 在第二页"读成"没有 PR"→ **重复建 PR**，正是 find-or-create 要
防的；两个精确匹配跨页时还会把冲突降级为静默复用。

修：读到尽，`@page_size 50` / `@max_pages 20`（1000 个 open PR 的硬上限）。超限
**拒绝**而非返回已读部分 —— 截断的列表与"无匹配"不可区分，会造出重复 PR。

**③ `forgejo_credentials` 的 `workspace_uri` 是装饰性的**

fetch/version/replace/delete 全部只按 `credential_ref` 查，租户列不参与任何边界。
而这张表登记在 `PerTenantTablesHaveWorkspaceColumnTest` 里，那条不变式的契约就是
"跨租户读是 miss 而非泄漏"。

修：
- `fetch_credential/2` 与 `replace/4` 要求 `workspace_uri` 并纳入查询（`replace` 的
  零命中经**收窄后**的重读区分 stale-version 与 absent）
- `lease_for_operation/1` 要求 `workspace_uri`。这是唯一以明文交出凭证的调用，
  `CredentialSource` 是其生产调用方且本就按 workspace 选中了 connection
- refresh 链：`begin_refresh_exchange/1` 从行里捕获 workspace 放进 `RefreshUse`，
  vault 一并存下 —— 因为 domain 的 refresh-path `replace/1`（`refresh.ex:449`）
  不带 workspace，轮转必须落回同一租户的行
- `version/1` **刻意不收窄**：`status/1` 与 `begin_refresh_exchange/1` 的命令都不带
  workspace（`termination.ex:138`、`refresh.ex:449`），无可比对象；它只返回整数、
  从不返回凭证材料

### 中严重度

**④ 两处 benign race 未回到完整 head reconciliation**

`POST /branches` 的 409 只比"是否仍在 base"，`POST /contents` 的 file-exists 422
直接判冲突。两个**相同**逻辑请求并发时，赢的那个写下的正是输的那个本该写的 commit，
却互相报冲突、无法收敛。

修：两处都走 `reconcile_head/3`，但**接受的状态不同** —— 409 后 `:at_base` 是常态
（并发者建了分支尚未写，本次继续写）；file-exists 422 后 `:at_base` 自相矛盾（文件
存在则分支不可能还在 base），接受它等于为没落地的写报成功。两处都仍由 `head_state/2`
拒绝非本次的 commit，所以都不会接到别人的分支上。只重读**一次**：`POST /contents`
不幂等，重试会叠第二个 commit。

**⑤ 文件路径未做 URI 编码**

`FileChange.valid_path?/1` 允许 `#`、`?`、`%`。原样插入 URL 后被解析成 fragment/
query，GET 读到**别的**资源（通常 404）→ 计划 `create` → Forgejo 对 JSON body 里的
真实路径回 file-exists 422 → 一个编码 bug 表现为并发冲突。

修：按段编码（保留 `/` 的分隔语义）。

### 低严重度

**⑥ `sha_required` 被错误归入 `:head_ref_conflict`**

它表示本 adapter 构造了缺 blob sha 的 `update` 操作 —— 是**内部构造错误**，不是并发
信号。按设计 §8 单独归为 `:invalid_file_change`，调用方才不会去重试一个无论远端怎么
变都不可能成功的请求。

### 由怀疑升级为确认：读路径分页

Codex 只提出怀疑（`list_reviews` 可能只读第一页）。**目标实例 swagger 实测坐实**
三个列表端点都接受 `page`/`limit`：`ListPullReviews`、`ListPullRequests`、
`/commits/{ref}/status`。

`list_reviews/3` 已改为读到尽（与 PR 列表共用 `all_pages/3`）。丢掉的是**最旧**的
review —— 早先那条阻断性的 `REQUEST_CHANGES` 恰好在那里，截断会读成"已批准"。

`list_checks/3` **未改**，理由写在代码注释里：它返回单个 CombinedStatus **对象**、
statuses 内嵌，分页对该对象做什么（切数组并重算 rollup？还是别的）未实测，而探针仓库
没有 CI 无法测。已写明这是已知残留限制与其证伪方法。

### Codex 明确未发现问题的部分

凭证 CAS 的 WHERE 条件、`credential_ref` 的 AAD 绑定、两个 `replace/1` 子句顺序、
`RefreshUse` 的不透明传递、caps 上下文对 task/caller/grantee/credential owner 的
workspace 约束。

## 12.3 第二轮 Codex review：四条缺陷，其中三条是「上一轮修得不完整」

第二轮专门要求它攻击第一轮的修复本身。结果比找新缺陷更有价值 —— **①②③ 都指向
我上一轮的改动**。

### ① 秒级精度：我上一轮引入的回归（已修）

`ours?/2` 改为比较时间戳后，用的是 `DateTime.compare` 精确比较。但
`commit_date` = `git_workflow_runs.inserted_at`，那张表是
`timestamps(type: :utc_datetime_usec)` —— **带微秒**；而 Git 以 epoch 秒存储
commit 时间，Forgejo 回显不带小数位（实测 `2026-07-29T16:14:17+08:00`）。

于是比较**永远不等**，adapter 认不出**自己写的** commit：每次响应丢失后的恢复都
报 `:head_ref_conflict` 而不是收敛。这比上一轮的 fail-open 换了个方向错 —— 不再
误认别人的，但也认不出自己的，恢复路径整条失效。

我的测试没抓到，因为 fixture 用了 `~U[... 10:00:00Z]`（微秒为 0）。**同一类问题
第二次出现**：上一轮是 stub 只记 message，这轮是 fixture 时间戳太干净。

修：`git_instant/1` 截断到秒，**写出去和比较用同一个值**。截断不削弱判据 ——
被丢掉的精度从来没被传输过。

### ② `ours?/2` 仍不比对 parent 与文件内容 —— 与设计冲突，未修

Codex 判为高严重度，理由是同一 head/title/date/身份下若先后收到两组不同
`file_changes`，第二次会把第一组判为 `:already_written`。

**但本设计 §7.6 明写**：

> **ref 已前进**时字段比对是充分判据；**ref 停在 base** 时无 commit 可比对，
> 这才是真缺口，与 GitHub 同源。

也就是说「字段比对充分」是这份设计已经作出的判断，而非疏漏。Codex 的场景要成立，
需要**同一个 run 的两次尝试产出不同内容** —— 而 Plan E §6.1 的确定性要求恰恰假定
内容在同一 run 的重试之间不变。

按 CLAUDE.md「不要发明新 Decision / 发现设计冲突就暂停明说」，**不在本 PR 里单方面
改判据**。这条留给人类裁决：要么确认 §7.6 的判断继续有效，要么把内容比对纳入设计
（代价是每个改动文件多一次 GET，且要在 `head_state/2` 之前完成 `file_operations`）。

### ③ 分页终止条件错：`limit` 是请求不是承诺（已修）

原实现把「返回条数 < 请求的 50」当作末页。但 `max_response_items` 是**实例级
配置**（探针实例 50，可配更低，实测 `GET /api/v1/settings/api` 返回
`{"max_response_items": 50, "default_paging_num": 30}`）。配成 20 的实例上，满页
返回 20 < 50 → 立即停 → 漏页 → 重复建 PR / 漏掉最旧的 `REQUEST_CHANGES`。

修：**只有空页才是末页**。代价是每次读多一个请求，换取与实例配置无关的正确性。

顺带把 stub 也改成真的分页，并把它的每页上限设为 **20**（模拟低于请求值的实例），
这样「短页 ≠ 末页」这件事在测试里可被表达 —— 原来的 stub 忽略 `page`/`limit`，
根本无法覆盖第 ③ 条。

### ④ handoff vault 先删后写（已修，残留窗口已记录）

`:ets.take/2` 在durable 写入**之前**删掉了轮转后凭证的唯一副本。写入失败则 token
永久丢失：provider 已使旧 refresh token 失效，而 domain 重试的是 `replace/1` 且只
带 opaque reference（`refresh.ex:449`），该 reference 再也解析不出来 → 每次
`:credential_conflict` → 重试预算耗尽后过期连接（`refresh.ex:28`）→ 用户重新授权。

修：改为**查、写成功、再删**。一次失败的写现在可重试，one-use 语义不变（成功后
删除，重放仍然冲突）。

**我在 §12.2 与 backend moduledoc 里写的理由是错的** —— 我写「丢了只是失败一次
refresh 而 domain 会重试」。domain 重试的是 `replace` 不是 exchange，同一个死
reference 永远解析不出来。已订正。

**残留窗口**：ETS 随进程死。`consume_refresh_exchange/1` 与 `replace/1` 之间重启，
仍会丢掉一次 provider 已经应用的轮转，代价是该用户一次浏览器重新授权。关闭它需要把
parked replacement 也做成持久（`forgejo_credentials` 旁边一张表）。**本 PR 不做**，
在此记录。

### ⑤ stub 的其它宽松处（低）

Codex 指出 stub 不校验 update 的 `sha`、建分支时不继承 base 文件、原样回显微秒
时间戳、且忽略分页。分页与时间戳已随 ①③ 修掉。`sha` 校验与文件继承**未做**：
它们会让 stub 更严格从而可能暴露更多问题，但属测试基础设施投资，记录待办。

### Codex 复核确认无误的部分

租户收窄（含四元组 vault 迁移点与 scoped 零命中判定）、两处 `reconcile_head/3` 的
状态区分、分段路径编码对 `FileChange.valid_path?/1` 字符集的覆盖、`sha_required`
映射、`list_checks/3` 已知限制的表述与代码一致。

## 12.4 内容比对落地 + 残留（2026-07-30）

第二轮 review 的 ② 经裁决采纳方案 B（比对改动文件的 blob sha），已实施。

### 关掉了什么

元数据全部巧合但内容不同的 commit 现在被识别为**非本次所写**：

| 场景 | 加强前 | 加强后 |
|---|---|---|
| 内容与我们要写的一致 | `:already_written` | `:already_written`（不变） |
| 内容不同 | **`:already_written`（错，会开出指向别人内容的 PR）** | `:head_ref_conflict` |
| 我们要写的文件在 head 上不存在 | **`:already_written`（错）** | `:head_ref_conflict` |

### 成本（实测）

- **首次执行：零新增请求。** `file_operations/2` 本来就为每个改动文件在 `head_ref`
  上读一次 blob sha（原先只用于决定 create-vs-update）。
- **恢复路径：+N 次 GET**（N = 改动文件数，通常个位数）。该路径原先判
  `:already_written` 后直接跳过写入，从不读文件，所以这 N 次是真新增。
- 期望值计算是纯本地的：`sha1("blob <byte_size>\0" <> content)`，无请求。

### 残留：不覆盖「顺手改了别的文件」

本判据证明**每个本次会写的文件已带有恰好该内容**，不证明同一 commit 里没有改动
其它文件。要闭合只能上方案 C（递归读全树 + 本地实现 git tree hashing）。

触发它需要攻击者/并发者先让 message、author、committer、commit date **和我们所有
改动文件的内容**全部一致，然后额外改一个我们不碰的文件。归 Plan E §6.2.1 同一条轨。

### 顺带修掉的第三处 stub 失真

`apply_file/2` 存的 sha 是 `sha1(base64字符串)` —— **不是任何真实实例会返回的值**。
之前没暴露，因为 adapter 只把它原样回传作为 update 的 `sha`；内容比对一上来，fixture
立刻站不住。已改为真实 git blob sha。

这是**同一类问题第三次出现**（① stub 只记 message；② fixture 时间戳微秒为 0；
③ 这次的 base64 哈希）。共同形状是：**测试替身比真实系统宽松，于是它无法表达那个会
失败的场景**。已记入 `.claude/skills/ezagent-developer/references/how-to-recipes.md`。

## 12.5 第三轮 Codex review：内容比对引入了新问题（已修）+ 一个门禁盲区

第三轮判定第三轮的改动"引入新问题"。四条确认缺陷全部核实属实并修复；另外**在修的过程中
发现一个更严重的问题：我前三轮一直在用错的门禁**。

### ① 内容读绑在可移动的分支名上（高，已修）

元数据取自**某一个** commit，内容却按 `head_ref` 读。分支能在元数据读与各次内容读之间
前进，于是每个文件可以各自命中期望内容，而**任何单个 commit 都不包含完整期望集合** ——
仍判 `:already_written`，开出 head 内容错误的 PR。

修：读绑定到 `commit["id"]`。实测坐实 `/contents` 接受 commit sha 作 `ref`。
并改用 `reduce_while` 首个不符即停 —— 外来分支只花 1 次读而非 N 次。

### ② 读失败被吞成"内容不符"（高，已修）

`/contents` 的超时 / 429 / 5xx 全被 `Enum.all?` 折成 `false` → `:head_ref_conflict`。
而 workflow 把它当**终态 blocker**（`blocker.ex:132`），所以一次瞬时读失败会把一个
**写入其实已经成功**的 run 永久卡死。直接违反设计 §8.3「传输失败意味着远端状态未知」。

修：`ours?/2` 改为三态 —— `{:ok, true|false}` 与 `{:error, marker}`。不知道就报错，
由 `map_error` 归成可重试的 provider 错误，而不是冒充"不是我们写的"。

### ③ 恢复路径实际是 2N 次读而非 N（中，已修）

`ensure_head` 判定一次，`ensure_commit` 又完整重做一次。`ChangeLimits` 允许
`max_files: 100`，所以一次恢复最坏 **200 次串行 GET**，且每次都是 ② 那种卡死的机会。

修：`ensure_head/3` 返回它建立的状态，`ensure_commit/4` 直接消费，不再重判。

**这处改动我自己引入了一个新 bug，被测试当场抓住**：我在 `ensure_head` 里硬编码返回
`{:ok, :at_base}`，丢掉了 409 路径 reconcile 出的 `:already_written` → 会重复写入
（`POST /contents` 不幂等，是真重复 commit）。改为让 `create_branch/3` 返回它建立的
状态。已加回归测试并变异验证。

### ④ 分页上限按页数计算，随实例页长缩水（中，已修）

`@max_pages 20 × 请求的 50 = 1000` 是**算错的**：页长由实例的 `max_response_items`
决定，配成 20 时实际可达量是 `19 × 20 = 380`，而非 1000。超限返回
`:provider_unavailable`（fail-closed，不会造重复 PR），但文档承诺的容量是假的。

修：上限改为按**条目**计（`@max_items 2_000`），与实例页长无关。

### ⑤ 单元 stub 忽略 `?ref=`（低，已修）

第三轮新增的三条内容 provenance 单测，**即使生产代码错误地去读 `main` 或完全漏掉
`ref` 也会通过** —— fixture 按 `request_path` 路由，对任何 ref 都回同一个 sha。

修：stub 把 `?ref=` 单独 `send` 给测试进程，新增测试断言读绑定到了 commit id。
同时 `apply_file/2` 现在按 branch **和** commit id 双键存文件，因为真实 Forgejo 能按
任意 ref 解析 —— 只按 branch 存会让"钉到 commit id 的读"变成 404。

**这是「测试替身比真实系统宽松」的第四、第五次**（stub 只记 message → fixture 微秒恒
0 → stub 存 base64 哈希 → stub 忽略 ref → stub 只按 branch 存文件）。

### 门禁盲区：`ci.fast` 不含 `mix test`，也不含 URI 扫描

修 ⑤ 时顺手跑了完整门禁，发现 **`mix ci.fast` 只有 4 步**（`ecto.create/migrate` +
`ezagent.check_invariants` + socialware + `gate.arch`）—— **它不跑 `mix test`，也不跑
`ezagent.uri_query.scan`**。后者属 `ci.local`。

我前三轮一直把 `ci.fast` EXIT=0 当"门禁绿"，于是漏掉了两条真实违规：

| 违规 | 内容 |
|---|---|
| `raw_cross_cutting_uri_construction` | 我手工拼 `"workspace://" <> name`，而 `Ezagent.URI.workspace_of/1` 本就能从 entity URI 派生出 tenant URI —— 既重造轮子，又绕过了每个读者都假定的规范化。已改用它，并把 `:any`（跨 workspace owner）显式拒绝 |
| `positional_uri_read` | `%URI{scheme: scheme, host: host} when scheme in [...]`。该 gate **本就为外部 URL 留了出口**（`scan.ex` 的 `external_url_pattern?/1`），但只认**字面量** `scheme: "http"`/`"https"`；绑到变量就对探测器隐身了。已改为逐子句字面量匹配 —— 让豁免诚实，而不是加宽规则 |

**教训**：`mix ci.fast` 是快速反馈，不是门禁。返回前应跑 `ci.local` 里 `ci.fast` 缺的那几步
（`deps.unlock --unused` / `format --check-formatted` / `ezagent.uri_query.scan` /
`world.e2e.fixtures --check`）+ 受影响 app 的测试。已记入项目 skill。

### Codex 明确排除的

`byte_size/1` 是字节数（UTF-8 / 空串 / NUL / LF / CRLF 五组与 `git hash-object` 完全
一致 —— 我独立实测过同样五组）；空 `file_changes` 被 `ensure_changes/1` 前置拒绝；
四处调用点无漏传或参数错位；无新的 caps 或三层边界违规。

### 那条怀疑已实测定性（2026-07-30，已修）

推 symlink（mode `120000`）与 gitlink（mode `160000`）到探针仓库后按 API 读回，
findings §8 有完整数据：

- **symlink 无害** —— `sha` 仍是标准 blob sha（内容为目标路径字符串），比较天然正确，
  且写普通文件时必然不等 → 正确判冲突。**不需要特例**，怀疑的这一半被推翻。
- **submodule / dir 坐实** —— 返回 commit sha / tree sha。危险方向不是误判为相同（需
  SHA-1 碰撞级巧合），而是**恒不相同** → 该路径被占据时永远报 `:head_ref_conflict`，
  一个 fail-closed 死锁穿着并发冲突的外衣。

已按 `type` 显式判定：`submodule`/`dir` → `:unwritable_path_kind` →
`:invalid_file_change`。**缺失 `type` 视为 file**（旧实例可能不返回，缺失不构成证据）。
读路径与写路径共用 `blob_sha/3`，所以两条路径同时受保护；变异验证杀死 2 条测试。

### 又一次「同一行」陷阱

修 `positional_uri_read` 时，我把解释性注释插到了 `# uri-canonical-allow:` 与
`URI.parse/1` 之间 —— 而 `UriCanonicalizationInvariantTest` **按行匹配**该标记，于是
豁免静默失效、gate 变红。两个 gate 对同一处代码有不同的形状要求：`uri_query.scan` 要
字面量 scheme，`UriCanonicalizationInvariantTest` 要 allow 标记同行。已在代码里写明。

## 12.6 第四轮 Codex review：读路径的两处 fail-open（已修）

第四轮换角度专攻读路径 —— 前三轮 15 条缺陷几乎全在写路径与凭证托管。**换角度立刻见效**：
两条确认缺陷都是 fail-open，且都在"上层据此决定能否合并"的路径上。

### ① submitted review 归一化失败被静默丢弃（高，已修）

`reviews/1` 用 `flat_map`，把三件不同的事折成同一个 `[]`：有意过滤的
`REQUEST_REVIEW`/`PENDING`、未知 state、无法解析的作者。

**危险形状是混合列表**：provider 返回一条正常 `APPROVED` + 一条 `user` 为 `nil` 的
`REQUEST_CHANGES` → adapter 只返回 approved → 上层记为 `1 reviews: approved=1`，
**人类明确要求修改的事件彻底消失**。

修：`review/1` 改为三态 —— `{:ok, [r]}` 保留、`{:ok, []}` 有意过滤（只对
`REQUEST_REVIEW`/`PENDING`）、`{:error, _}` 拒绝整次读取。宁可整体失败也不返回一个
读起来像"没有阻塞"的部分答案。

**我原有的两条测试把这个 fail-open 钉死了**（断言未知 state 返回 `{:ok, []}`、缺
author 返回 `{:ok, []}`）。测试名叫 "dropped rather than guessed" —— "不猜相邻状态"是对
的，但和"静默丢弃"是两件事，我把它们混为一谈了。已改为断言正确行为。

### ② 缺 `statuses` 键被伪造成"没有 checks"（高，已修）

`checks(%{})` catch-all 对任何缺 `statuses` 的 map 返回 `{:ok, []}`，而**紧邻的上一条
子句**对非列表是拒绝的 —— 自相矛盾。

`"statuses": nil` 是**实测过**的（无 CI 的 commit，键存在）；**缺键从未被观测过**。对未
实测的形状回答"没有 checks"，上层会写入 `no checks reported`，已存在的失败 check 从阻塞
事实中消失。

修：删掉该 catch-all，未识别形状一律拒绝。

### 实测否掉的怀疑

**`warning -> :neutral` 会降级 failure** —— 不成立。目标实例接受 `warning` 且 rollup
保持 `warning` 而非 `failure`（findings §9.3）；且上层 `observation_summary` 不做阻塞
判定、只原样计数标签，`:neutral` 会如实出现。

### 实测确证的设计判断

组合端点按 context 去重并**保留最新**（`ci/test` failure→success 后留 success）——
实证了选组合端点而非历史端点的理由（findings §9.2）。

### 追加：`status` / `state` 命名不一致引出的第三处同族 fail-open（已修）

swagger 确认 `CommitStatus.status` 与 `CombinedStatus.state` 是**同一个 Go 类型**
（`CommitStatusState`）序列化成两个 JSON 名 —— 上游命名不一致，不是语义区分。**正因为
不是语义区分，它才是版本升级最可能改名的那类字段。**

原实现 `check_state(status["status"])`：字段缺失或改名 → `nil` → 落到
`check_state(_unknown)` → `{:completed, :other}`。实测两种输入都返回 `{:ok, ...}`，
即**每条 check 静默降级**而非拒绝。

修：`status` 必须是 binary，否则走 `check/1` 的 fallback 拒绝。保留"未知**值**仍为
`:other`"—— `:other` 的意思是"这个状态我们没有映射"，不是"我们找不到状态"。

### 关于 `official` / `stale`：GitHub 没有对应字段

回答"GitHub 怎么处理"：**GitHub 的 API 根本没有 `official` / `stale`。** 它的等价机制是
两条：

1. **分支保护的 `dismiss_stale_reviews`** —— 开启后，新 commit 会让旧批准自动变成
   `DISMISSED`，所以"陈旧"这件事体现在 **state 本身**里，而不是一个旁路布尔
2. **GraphQL 的 `reviewDecision` rollup**（`APPROVED` / `CHANGES_REQUESTED` /
   `REVIEW_REQUIRED`）—— 这才是"是否满足合并要求"的答案

**两个 adapter 都不读第 2 条。** 所以在当前契约下，Forgejo 侧给的信息其实**比 GitHub 更
多**（它把 `official`/`stale` 明确暴露出来），只是我们没用。

### 顺带发现：GitHub adapter 有同族且更严重的 fail-open（不在本 PR 范围）

`github_adapter.ex:674-683`：

```elixir
defp map_review_state(state) when is_binary(state) do
  case String.upcase(state) do
    ...
    _ -> :commented        # 未知 state → 编造成"评论"
  end
end

defp map_review_state(_), do: :commented   # 字段缺失/非字符串 → 同样编造
```

比 Forgejo 原来的静默丢弃更危险：丢弃至少让计数变少（可能被察觉），**编造成 `:commented`
则让一条 `CHANGES_REQUESTED` 变成"有人评论了、无阻塞"**。`map_check_status(_)` 与
`map_check_conclusion(_)` 也是同样形状。

属 GitHub owner 的代码，本 PR 不改。建议单开一条。

### `official` / `stale` —— 契约已裁决（gaga 2026-07-30）

**裁决：DomainGit `Review` 是历史事件流，不是"当前有效的 gate"。**

因此当前实现**正确**：`official` / `stale` 不读取，adapter 如实汇报"发生过哪些 review
事件"，由上层自行解释。这与 `observation_summary.ex:124` 的既有行为一致（按全部事件
计数，不按 reviewer 取最新）。

**该裁决同时确立一条边界**：这些值**不能直接用于自动合并判定**。任何"够不够批准数"
的判断都需要额外信号（Forgejo 侧是 `official`/`stale`，GitHub 侧是 GraphQL
`reviewDecision`），两个 adapter 目前都不提供。要做自动合并，得先扩契约。
- **`merged_at` 与 `merged` 的异常组合**。已实测 closed-unmerged 为
  `state:"closed", merged:false, merged_at:null`（正确映射为 `:closed`）；未穷举
  merged / draft 的原始 JSON。

## 13. 未决 / 待人类决定

0. ~~**DomainGit `Review` 的契约语义**~~ —— **已关闭**（gaga 2026-07-30）。是**历史
   事件流**，不是当前有效 gate。`official`/`stale` 不读取是正确的；代价是这些值不能
   直接用于自动合并判定。详见 §12.6。

1. ~~**§4.3 帐号级隔离**~~ —— **已关闭**（2026-07-29）。改走 OAuth 后每个用户
   用自己的帐号授权，爆炸半径由用户本人已有权限封住，是机制保证而非运维约定，
   不再需要人类拍板。
2. ~~**§4.1.1 per-repo 收窄未实证**~~ —— **已关闭**（2026-07-29）。帐号新建第二个
   仓库后复测坐实：签发在前的 OAuth token 看得见创建在后的仓库，授权持续跟随
   帐号而非签发时快照。见 §4.1.1 与 findings §7.3。
3. **§8.3 是否回头统一 `GitHubClient` 的传输/5xx 区分** —— 跨 owner 改动，
   本设计不做，建议单独一片。
4. **GitHub 凭证是否也持久化** —— §12.1 论证了不急：它存的 token 仅用于识别
   身份，仓库权限每次操作现签。真正该触发统一的是 capbac Path B（外部签名器 /
   HSM）落地时把全仓 AES 实现一起收敛，那时 core 才会有密封 seam。
5. **`redirect_uri` 匹配规则**（精确 / 前缀 / 是否允许 http+localhost）未测。
   只影响给租户管理员的注册说明，不影响代码结构；F0 实施时顺带验。
6. ~~**OAuth 请求哪些 scope**~~ —— **已关闭**（2026-07-30）。用 OAuth token 走了
   一次真实写链（建分支 → `POST /contents` → 开 PR），三步全 `:ok`，坐实
   `["write:repository", "read:user"]` 够用。走的是插件自己的代码路径，所以
   `ForgejoOAuth.exchange_code/4` 对真实实例也一并验证了。见 findings §7.5。
7. **版本探测策略** —— 一个 adapter 服务 Forgejo + Gitea，探测到什么程度、
   不兼容时如何降级，本设计未定。建议先记录版本到 telemetry，不做行为分支。
8. **§9.2 / §9.3 的 ⚠️ 取值** —— `error` / `warning` / `REQUEST_CHANGES` /
   `COMMENT` / `PENDING` 未在采样中观察到，实施时实测确认；无论如何未知值
   必须走 `:other` / 丢弃，不得崩溃。
9. **§2.2 的 PR 端点行为待在目标实例复核** —— 现有结论采自 Codeberg
   16.0.0-dev，目标实例是 15.0.5。结论不变则 §7.4 直接落地；即使不同，
   §7.4 仍是安全选择。

---

## 14. 完成声明

**F1–F5 全部完成，F5 已在真实实例上通过**，因此现在可以声明：

> Forgejo provider V1 本地 provider-owned PR loop 当前切片完成，
> **并已在真实 Forgejo 实例（`code.hyprial.com`，`15.0.5+gitea-1.22.0`）上验证**：
> 建分支、提交、开 PR、回读 PR/checks/reviews，且同一输入重跑不产生第二次 mutation。

**不得声明**（继承 Plan E §11，逐条适用）：

- Git Provider E2E 生产闭环完成；
- production authorization 已接线；
- managed Agent canary 已完成；
- Forgejo merge loop 已完成；
- Kanban / socialware projection 已完成。

Plan E §10 的 operator gate **未解除**，Forgejo 线继承同样的边界。
