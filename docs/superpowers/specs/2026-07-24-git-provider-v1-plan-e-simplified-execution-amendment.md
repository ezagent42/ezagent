# Git Provider V1 Plan E 简化执行修正案

**状态：** 待 lead 书面确认；确认前不得编写新 implementation handoff、实施生产代码或操作 canary

**日期：** 2026-07-24

**设计分支：** `integration/git-provider-v1-plan-e`

**设计基线：** `7e3ee6560ab4cf641870ca9496e74b5c3033ccf2`

**受管控主工作区：** `/home/huangjiajia/ezagent`，固定 `main`，本任务只读

## 1. 结论

Plan E 的产品目标不变：

```text
Kanban task
→ managed Agent
→ isolated worktree
→ create PR
→ observe CI and independent review
→ human/lead merge in GitHub
→ fresh-read confirmed Git facts
→ Kanban projection
```

本修正案只改变实施机制：

1. 目标认证模型确认采用 **GitHub App**。当前生产使用的 OAuth App 是迁移前现状，
   不作为 Plan E repository-operation canary 的认证路径。
2. GitHub App installation token 在 V1 采用 **operation-scoped mint**：每个封闭
   provider operation mint 一次，可在该 operation 的有限 HTTP 批次内复用，返回
   前丢弃；不进入共享 ETS、常驻 GenServer、workflow state 或 Agent surface。
3. task claim 只验证权限并持久化 durable workflow intent，不在 claim 调用中一次性
   spawn 三套 policy、issue/store/verify 全部 capability。
4. workspace、worker、authority、provider mutation 和 observation 按 durable state
   分阶段推进。跨 PostgreSQL、Kind runtime 和 capability store 使用幂等
   reconciliation，不承诺不存在的跨系统原子事务。
5. 第一条生产垂直切片只闭合
   `accepted → isolated worker → exact GitTaskAccess → create PR → confirmed PR fact`。
   CI、review、merge-confirm、Kanban、skill/socialware 和 canary 在后续独立切片增加。

本修正案在冲突处取代：

- `2026-07-23-git-provider-v1-plan-e-integration-clarification.md` 中 D6
  “pre-hardening canary”例外和共享 token cache hardening 方案；
- `2026-07-23-git-provider-v1-plan-e-multi-worker.md` 中 Task 1 的共享 cache
  状态机和 Task 2 的 claim-time 全量 authority materialization；
- 旧 Worker A/A2/H/H2 handoff。旧分支只保留研究证据，不得整体 merge 或
  cherry-pick 到新的 integration 基线。

## 2. 已确认事实与代码基线

### 2.1 部署事实与目标事实不同

Lead 已确认当前生产注册形态是 OAuth App，后续迁移到 GitHub App。当前代码已经
按目标模型区分两种职责：

- `GitHubOAuth` 把 OAuth 描述为 GitHub App user-to-server identity flow，明确
  repository access 不来自 user token
  （`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_oauth.ex:1-14`）；
- `GitHubAdapter` 的 repository callbacks 已从 `GitHubInstallation` 取得
  installation token
  （`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex:8-13`,
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex:32-36`,
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex:363-370`）。

因此 Plan E 不是把 OAuth App token 接到现有 adapter，而是完成代码目标与部署目标
之间的 GitHub App migration。旧 OAuth App credential 不得静默复用、转换或作为
installation credential fallback。

### 2.2 当前 installation token 实现不适合作为生产基线

当前 `GitHubInstallation`：

- 按 account 共享缓存 token
  （`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex:17-23`,
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex:77-86`）；
- 暴露 `put_cached_token/3`
  （`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex:89-100`）；
- mint body 是空 map，没有把 repository 和 permission profile 固定进请求
  （`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex:104-118`）。

这些问题必须修复，但不需要用 reservation/owner/ref/timer/waiter 协议替换。
V1 直接删除共享 cache，可同时删除由 cache 引入的竞争、泄漏和 takeover 状态。

### 2.3 Git domain 已有 exact policy，不应被 GitHub 认证细节污染

`GitTaskAccess` 已冻结 workspace、credential owner、grantee、repository、adapter、
head ref、actions 和 idempotency inputs
（`apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex:30-69`）。
ActionSet 已提供 create/read/check/review 和 workspace provision/cleanup 的
provider-neutral vocabulary
（`apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex:24-40`）。

本修正案不新增 GitHub 字段、token 类型、installation id 或 OAuth/App mode 到
`RepositoryRef`、`GitTaskAccess` 或 `DomainGit.Adapter`。

## 3. 备选方案与选择

### 方案 A：继续修补共享 cache 与 claim-time 全量 materialization

优点是最大程度保留旧 A/H 分支。缺点是必须维护 token reservation 并发协议，并
假装 PostgreSQL、Kind spawn 和 cap store 能被一个 claim 事务原子提交。A2/H2
已经证明该方向产生大量内部结构测试和反复返工。

**结论：拒绝。**

### 方案 B：同时支持 OAuth App 与 GitHub App repository operation

优点是可以先用当前 OAuth App 跑 canary。缺点是建立一条即将淘汰的生产 mutation
路径，引入 credential fallback、双模式迁移和更大的测试矩阵。

**结论：拒绝。** OAuth App 只保留为迁移前运行事实，不进入 Plan E canary。

### 方案 C：GitHub App 前置、无共享 token cache、durable staged workflow

优点是直接验证目标安全模型，删除非必要缓存协议，并让每个 workflow 阶段拥有
可恢复的 durable 边界。代价是 canary 必须等待 operator 完成 GitHub App 注册、
安装和 secret reference 配置。

**结论：采用。**

## 4. GitHub App E0 迁移契约

### 4.1 Identity 与 repository authority

目标模型：

```text
GitHub App user-to-server OAuth
  → 识别并绑定连接用户

GitHub App JWT + installation
  → 为指定 repository 和 permission profile mint installation token
  → 执行 repository operation
```

身份连接和 repository mutation 是两条不同 authority 链。成功 OAuth 登录不代表
App 已安装到目标 repository；缺失 installation 必须在 provider mutation 前返回
稳定 blocker。

### 4.2 迁移规则

- 新 GitHub App 使用新的 provider fingerprint/config generation。
- 旧 OAuth App credential reference 不得重标记为 GitHub App credential。
- 不允许 OAuth App 与 GitHub App 之间自动 fallback。
- 需要 user-to-server identity 的现有用户按 operator migration policy 重新授权。
- repository binding 只保存 provider-neutral repository identity、credential
  owner 和 governed connection identity；GitHub plugin 根据 repository 在内部
  resolve installation。binding 不保存 installation id、private key、OAuth token
  或 installation token。
- App private key、client secret 和 webhook secret 只能以 runtime secret
  reference 进入部署配置，不能进入 prompt、card、run、日志或 tracked evidence。

### 4.3 Operator 输入

在任何真实 provider mutation 前，operator 提供：

1. GitHub App id 和 private-key runtime secret reference；
2. GitHub App OAuth client 配置 reference；
3. App installation/account reference；
4. 已安装的单一 disposable canary repository；
5. App granted permissions 与 selected-repository 审计结果；
6. base branch、受控 head namespace 和 required check names；
7. canary user/workspace/session/coordinator/worker/task/card；
8. independent reviewer 与 lead merge 权限；
9. webhook 或 polling 运行选择。

只记录 reference 与安全坐标，不读取、打印或提交 secret 本体。

## 5. Operation-scoped installation token

### 5.1 生命周期

一个 provider operation 的 token 生命周期：

```text
validated GitTaskAccess invocation
→ adapter selects a closed permission profile
→ sign App JWT
→ resolve installation for exact repository
→ mint token for exactly that repository and permission map
→ verify response repository_selection/repositories/permissions/expires_at
→ execute the callback's bounded GitHub HTTP batch
→ map response to normalized DomainGit values
→ drop token before callback returns
```

“一个 operation”对应一个 `DomainGit.Adapter` callback 或一个明确的 observation
tick，不对应单个 HTTP request，也不跨 sleep、poll interval、workflow step、
task、repository 或 process restart。

### 5.2 Permission profiles

profile 由 adapter callback 选择，Agent/action args 不得选择：

| Operation | 最小 profile |
|---|---|
| `resolve_repository` | metadata read |
| `create_change_request` | metadata read + contents write + pull requests write |
| `read_change_request` | metadata read + pull requests read |
| `list_checks` | metadata read + checks read |
| `list_reviews` | metadata read + pull requests read |

V1 没有 provider merge action；human/lead 在 GitHub merge，系统只 fresh-read 确认。

### 5.3 信任边界

V1 的不可信主体是 managed Agent、sidecar、action caller、prompt/card 数据和外部
provider response。BEAM VM 内经过 review 的 plugin code 属于同一可信计算基。
本设计不声称 GenServer/ETS 可以抵抗任意恶意本地 BEAM code；若未来插件代码也被
视为不可信，必须采用进程外 credential sidecar/HSM，而不是继续加 ETS 隐藏技巧。

约束：

- token 不得进入任何 Agent-callable action 的参数或返回值；
- token 不得进入 ETS、长生命周期 GenServer state、process dictionary、run DB、
  event/audit、日志、错误、snapshot 或 evidence；
- plugin 内部可信函数可以在当前 callback 调用栈中持有 token bytes；
- callback 返回前 token 不再被任何持久或共享结构引用；
- response scope mismatch 在执行 repository mutation 前 fail closed；
- missing/malformed App config fail loudly，并与 GitHub 401/403 区分。

### 5.4 Observation 策略

一个 observation tick mint 一次 token，并在同一 tick 批量读取所需 facts。tick
之间不保存 token。优先 webhook 触发 fresh-read；需要 polling 时采用有界退避：

```text
15s → 30s → 60s，随后保持 60s，直到 deadline
```

run 记录 mint count、provider latency、rate-limit safe metadata 和最后 observation
时间，但不记录 authorization header、token 或 raw response body。只有数据证明
operation-scoped mint 成为瓶颈后，才单独设计 workflow-local reuse；不得在 Plan E
内顺手恢复全局 cache。

## 6. Durable staged workflow

### 6.1 Claim 边界

`TaskIntake.claim` 只做：

1. 从 reviewed ingress 读取 `authenticated_principal`；
2. 通过统一 `Cap.authorize/3` 验证当前 holder 和 target workspace authority；
3. 加载并验证 governed binding；
4. 写入一个 durable, non-secret workflow intent；
5. 用数据库唯一约束和原子 CAS 返回同一 run identity；
6. 调度 runner。

claim 不做：

- `GitTaskAccess` Kind spawn；
- cap issue/store；
- workspace clone/worktree；
- managed Agent spawn；
- sidecar start；
- GitHub HTTP；
- CI polling；
- Kanban done projection。

claim 成功只表示 `status: :accepted`，不表示 workspace、worker 或 authority 已就绪。

### 6.2 状态机

成功路径：

```text
accepted
→ workspace_ready
→ worker_ready
→ authority_ready
→ pr_open
→ checks_passed
→ awaiting_external_merge
→ merged_confirmed
→ projected
→ completed
```

控制状态：

```text
任意非终态 → blocked | failed | cancelled
```

每次转换使用单条数据库 CAS：

```text
WHERE run_id = ? AND state_version = expected
SET status = next, state_version = expected + 1
```

同一 transition 的精确重试返回已确认结果；不同输入、generation、policy digest
或 provider fact revision 返回 closed conflict。

### 6.3 Authority materialization 时序

authority 不在 claim 时一次性创建：

1. `accepted → workspace_ready`：runner 通过既有 owner-gated task workspace seam
   provision 并验证 isolated `project_cwd`；
2. workspace 成功后创建 deterministic exact worker principal；
3. worker principal 存在后，创建 worker `GitTaskAccess` policy，使用 sanctioned
   capability issue/store/strict-verify seam；
4. strict verification 成功后写 `authority_ready`；
5. 只有 `authority_ready` 才允许启动 sidecar 和交付 Git task；
6. coordinator observation policy 在进入 provider observation 前按 deterministic
   identity materialize；
7. lifecycle cleanup authority 由 runner/coordinator 持有，绝不授予 author Agent。

cap/policy materialization 不与 run row 假装成一个事务。run 持久化 deterministic
obligation、policy URI/digest、attempt 和 verified result；reconciler 对相同 identity
幂等重试，并清理未被 durable result 接受的 orphan。任何阶段失败都留下明确状态，
而不是要求跨系统“看起来从未发生”。

### 6.4 Agent action surface

author Agent 只得到 exact worker policy 中批准的 actions：

```text
resolve_repository
create_change_request
read_change_request
list_checks
list_reviews
```

author Agent 不得到：

```text
provision_workspace
cleanup_workspace
submit_review
merge
```

Agent 只能调用 server-side sanctioned workflow facade；不得使用 `gh`、raw HTTP、
bearer token、raw RPC、runtime cookie 或读取环境 secret。

## 7. 最小垂直切片与依赖

| Slice | 交付结果 | 依赖 | 可独立拒绝原因 |
|---|---|---|---|
| E0 | GitHub App migration/config/install readiness contract | 无 | 旧 OAuth credential 被复用、缺 installation、secret 泄漏 |
| E1 | 无共享 cache 的 operation-scoped installation credential | E0 | scope 非单 repo、permissions 可由 caller 选择、token 外泄 |
| E2 | `accepted` workflow intent + 原子 run CAS | 最新 main | claim 产生 lifecycle/provider side effect、CAS 非原子 |
| E3 | isolated workspace → exact worker → authority_ready | E2 | sidecar 先于 cwd/authority、policy 非 exact、不可恢复 |
| E4 | managed Agent create PR → confirmed `pr_open` fact | E1、E3 | raw GitHub path、Agent 得 token、未 fresh-read |
| E5 | checks/reviews observation → awaiting external merge | E4 | 无界 polling、required checks 不闭合、事实不单调 |
| E6 | human merge → fresh-read `merged_confirmed` | E5 | author/coordinator自行 merge、仅凭 webhook/card 宣称 merged |
| E7 | provider-neutral Kanban projection | E4–E6 | Kanban 做 HTTP、接受 caller supplied Git status |
| E8 | skill/socialware registration 与 orchestration | E4–E7 | manifest 授权、`gh` fallback、secret/credential reference 进 prompt |
| E9 | integration gate、部署 handoff、真实 canary | E0–E8 | test seam、secret evidence、未授权 canary |

E1 与 E2 可从同一个最新 main 基线并行；E3 依赖 E2；E4 是第一个跨层垂直验收点。
E5–E8 不在 E4 之前并发实施，以免在未证明真实 create-PR seam 前堆叠 UI/skill。

## 8. 测试策略

每个 slice 只要求三层证据：

1. **Contract tests**：public input/output、closed errors、idempotency；
2. **One real integration path**：真实 Repo/Kind/Cap 或 Req.Test，不 mock 关键
   authorization/mint/materialization seam；
3. **Architecture gates**：provider-neutral、CapBAC chokepoint、workspace locality、
   no secret exposure、no raw HTTP/`gh`。

禁止用测试锁定非契约内部结构，例如 ETS table id、GenServer state tuple 或私有
message shape。允许对 production public API absence、Agent action vocabulary 和
tracked secret sentinel 做结构 gate。

### 8.1 E1 必测

- exact repository 和 exact permission request；
- malformed/wider response fail closed；
- callback 内有限复用，callback 间无 token reuse；
- no ETS/cache/public token getter；
- token sentinel 不进入 action result/log/error/state；
- missing/malformed config fail loudly；
- OAuth App credential 不被当作 installation credential。

### 8.2 E2/E3 必测

- unauthorized claim 零 workflow side effect；
- authorized claim 只产生一条 `accepted` intent；
- concurrent same claim 返回同一 run；
- concurrent same `state_version` 只有一个 transition 成功；
- workspace/worker/authority 每阶段 deterministic + idempotent；
- exact worker 不存在时不 self-store worker cap；
- authority_ready 前不能启动 sidecar；
- crash 后从 durable status 重建，不重复 accepted side effect。

### 8.3 E4 垂直验收

真实集成测试必须从 accepted run 开始，经 isolated worktree 和 exact worker
authority，通过 `GitTaskAccess`/GitHub adapter 创建 PR，并保存 normalized、
fresh-read confirmed PR fact。不得直接调用 adapter、手动插 DB、替换 registry、
传 token 或绕过 sidecar ordering。

## 9. 旧分支处置

以下分支不进入新的 integration history：

- `feat/git-provider-v1-plan-e-workflow-owner`
- `test/git-provider-v1-plan-e-workflow-contract`
- `fix/github-installation-token-hardening`
- `test/github-installation-token-reservation-contract`

处置规则：

- 保留 worktree/branch 直到本修正案和新 plan 获批，作为 forensic evidence；
- 不继续 A2/H2 correction；
- 不整体 merge、rebase 或 cherry-pick；
- 新 worker 可以阅读其 review findings，但测试必须按本修正案重新编写，不能携带
  cache reservation 或 claim-time atomicity 假设；
- 删除/归档由 lead 在新 E1/E2 通过后另行决定，本修正案不执行 destructive action。

## 10. 基线与派工门禁

当前 integration HEAD 是 `7e3ee6560...`，当前受管控 main HEAD 是
`62f606b8f...`。`7e3ee6560...` 是 main 的 ancestor；其后当前只有一个与本范围
无关的 PostgreSQL 注释/死代码清理提交，但任何新 worker 仍不得使用旧 integration
SHA。

书面设计确认后，lead 必须：

1. 只读 fetch/核对最新 `origin/main`；
2. 不切换或修改 main worktree；
3. 从 lead 记录的最新 main SHA 创建新的 Plan E integration branch/worktree，或按
   repository governance 明确迁移当前 integration branch；
4. 为 E1/E2 分别创建全新 linked worktree；
5. 在 handoff 中写死 repo、worktree、branch、base SHA、owner surface 和 tests；
6. E1/E2 return 由 lead 独立 review，不能由 worker 自我验收；
7. E4 前不操作 canary。

## 11. 完成定义

本修正案的设计阶段完成条件：

- lead 书面确认 GitHub App 目标、无共享 token cache、staged workflow 和旧分支
  不集成；
- implementation plan 为 E0–E9 分配独立、可拒绝的 PR slices；
- E1/E2 handoff 使用最新 main 基线并全中文；
- 没有未决的 CapBAC exemption、跨层依赖或 credential fallback。

Plan E 产品完成条件仍是：

- real managed Agent 在 isolated worktree 中通过批准 action 创建 PR；
- CI 与 independent review 被 provider fresh-read 确认；
- human/lead 在 GitHub merge；
- coordinator fresh-read `state: :merged`；
- Kanban 只投影 confirmed facts；
- cleanup 闭合；
- canary evidence redacted、secret-scanned，并由 lead 验收。

## 12. 本文不授权的动作

本文不授权生产代码、push、PR、deployment、secret read、GitHub mutation、canary、
main branch 操作或删除旧 worktree。书面确认后只进入 implementation planning；
每个实施动作仍需新的 lead handoff。
