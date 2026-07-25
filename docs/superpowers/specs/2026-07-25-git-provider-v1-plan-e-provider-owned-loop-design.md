# Git Provider V1 Plan E Provider-Owned PR Loop Design

**状态：** 待 lead review

**日期：** 2026-07-25

**协调分支：** `integration/git-provider-v1-plan-e`

**设计基线：** `0027766ed7b210a50a9b9738c06ba3f04b2ac81d`

**包含 main：** `origin/main@846265571`

**受管控主工作区：** `/home/huangjiajia/ezagent`，固定 `main`，本任务只读

## 1. 目标

优先闭合一条本地可重复验证的生产形状：

```text
already-authorized task intake
→ durable accepted run
→ isolated task workspace
→ deterministic head branch
→ collect bounded text changes
→ GitHub App operation-scoped installation token
→ provider-owned Git commit
→ create-or-reconcile PR
→ fresh-read PR, checks, reviews
→ persist confirmed provider-neutral facts
```

同一任务、同一 generation、同一输入重复执行时：

- 复用同一 workflow run；
- 复用同一 deterministic head branch；
- 复用同一远端 commit 或确认等价 head；
- 复用同一 PR；
- observation 只刷新 facts，不制造 provider mutation。

任何阶段失败必须满足其一：

- 可重试且保留明确的 durable resume point；
- fail closed，保存稳定错误码并停止；
- 发现输入、base、branch、PR 或 provider fact 冲突后明确停止。

本切片不接线上 ingress，不操作 canary，不新增 cap 发放逻辑。

## 2. 已冻结选择

### 2.1 Provider-owned commit

采用 GitHub Git Data API 写入：

```text
workspace changes
→ Ezagent.DomainGit.FileChange
→ DomainGit.Adapter.create_change_request/4
→ GitHub blob/tree/commit/ref/PR
```

不在 V1 中把 installation token 注入 `git push`、credential helper、Agent
environment、task cwd 或 sidecar。

现有契约已经接收 `[FileChange]`：
`apps/ezagent_domain_git/lib/ezagent/domain_git/adapter.ex:32-37`。

现有 GitHub adapter 已实现 blob/tree/commit/ref/PR 请求链：
`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex:93-185`。

### 2.2 V1 change envelope

V1 只支持：

- UTF-8 regular text file；
- `:upsert`；
- 路径位于已验证 task worktree 内；
- 文件数、单文件字节数和总字节数受 `ChangeLimits` 限制；
- 无 symlink、submodule、`.git/**`、删除、重命名、mode change 或 binary。

不支持的 change 必须返回稳定 blocker，不得静默忽略。完整 Git push、删除、
rename、binary 和 executable bit 留给后续 V2。

### 2.3 Human merge

V1 不新增 provider merge action。系统只创建 PR 并回读 PR、checks、reviews。
真实 merge 继续由 human/lead 在 GitHub 执行；线上 merge confirmation 与 canary
不在本切片。

## 3. 权限边界

### 3.1 单一可替换 seam

workflow 只依赖一个内部执行 seam：

```elixir
@callback authorize(run, binding) ::
  {:ok, authorized_task}
  | {:error, :authorization_unavailable}
  | {:error, :not_authorized}

@callback invoke(authorized_task, action, typed_args) ::
  {:ok, typed_result}
  | {:error, term()}
```

`authorized_task` 至少封装经过验证的 exact `GitTaskAccess` policy、task URI 和
generation；不得包含 raw cap、`%Invocation{}`、`ctx.caps`、GitHub token 或任意
caller-supplied credential。

生产默认实现始终返回 `:authorization_unavailable`，并在 workspace、filesystem、
provider 和 Agent side effect 之前 fail closed。

本地端到端测试注入显式 test-authorized backend。该 backend 只能通过依赖注入进入
测试调用，不得由 runtime env、route、ActionSet、CLI 或 Agent 参数启用。

### 3.2 当前明确禁止

- 新增 `Cap.issue/store` 或 cap materialization；
- 推导 caller/authenticated principal；
- 修改 `EntityCaps`、`PresenterCaps` 或 CapBAC 内部；
- 在 workflow 中构造或扩散 `%Invocation{}`、`ctx.caps`；
- public route、controller、ActionSet registration、CLI、Mix task 或 agent tool；
- workflow 直接依赖 GitHub plugin；
- token、authorization header、private key、installation id 或 raw provider body
  进入 workflow rows、events、logs、errors、workspace 或 Agent。

最终 production authorization backend 等 V1/V2 sanctioned contract 后接入；替换
backend 不得改变 workflow state、idempotency key 或 provider facts schema。

## 4. 组件边界

### 4.1 Workflow owner：`ezagent_plugin_git_workflow`

负责：

- typed intake 和 durable run；
- legal state transition；
- deterministic head ref；
- orchestration/reconciliation；
- provider-neutral workspace/PR/check/review facts；
- retry classification 和 operator-facing error projection。

不负责：

- GitHub HTTP；
- token mint；
- git subprocess；
- cap 发放；
- caller identity；
- workspace 路径拼接。

### 4.2 Workspace owner：`ezagent_domain_workspace`

新增或扩展 provider-neutral workspace-change port 的实现：

- 以 `provision_id + exact task/generation proof` fresh-read ready provision；
- 返回已验证 `project_cwd`；
- 从 owned worktree 收集 V1 change envelope；
- 规范化为 `[Ezagent.DomainGit.FileChange.t()]`；
- 拒绝越界路径、symlink、binary、删除、rename、mode change 和超限内容；
- 不执行 provider HTTP，不接触 token。

workflow 不直接运行 `git` 或自行解析 `.git`。

### 4.3 Git domain：`ezagent_domain_git`

保持 provider-neutral。允许新增最薄的 workspace-change port/value request，
但不得加入 GitHub installation、token 或 REST response shape。

冻结现有 adapter action vocabulary：

- `create_change_request`
- `read_change_request`
- `list_checks`
- `list_reviews`

本切片不新增 merge action。

### 4.4 GitHub owner：`ezagent_plugin_github`

负责：

- 每个 adapter callback mint 一次 operation-scoped installation token；
- deterministic ref create-or-reconcile；
- commit create-or-reconcile；
- PR find-or-create；
- GitHub HTTP error 到 closed DomainGit error 的映射；
- PR/check/review response 到 DomainGit typed values 的映射。

workflow 不得感知 GitHub branch lookup query、installation id 或 PR API shape。

## 5. Durable model

### 5.1 Run identity

继续使用：

```text
(binding_id, binding_generation, external_task_id)
```

作为唯一键，input digest 检测同一任务的不同输入冲突。

### 5.2 Deterministic branch

head ref 必须由服务端派生：

```text
binding.allowed_head_namespace
+ "run-"
+ first_24_hex(run.id sha256 portion)
```

约束：

- 不包含 task title、prompt、用户名或任意 secret；
- 满足 Git ref validation 和 255-byte 上限；
- 相同 run 永远得到相同 ref；
- caller-supplied `requested_head_ref` 只能为空或与派生值完全相同；
- 同 ref 已存在但不属于预期 base/commit chain 时返回
  `:head_ref_conflict`，不得 force push。

### 5.3 Durable facts

run row 只保留整体状态、版本、稳定错误码和 intent identity。新增独立的 typed fact
storage，至少保存：

- workspace provision id；
- deterministic head ref；
- collected change digest；
- expected base SHA；
- created/reconciled head SHA；
- normalized change request id、URL、state、head/base ref；
- checks observation revision、summary 和 observed_at；
- reviews observation revision、summary 和 observed_at。

不得保存 raw response body、headers、token、credential value 或任意 arbitrary
payload map。checks/reviews 若保存明细，应使用明确 typed columns/rows，而非无界
JSON blob。

### 5.4 State machine

本切片使用实际执行顺序：

```text
accepted
→ authorized
→ workspace_ready
→ changes_ready
→ pr_open
→ observations_current
```

控制状态：

```text
任意非终态 → blocked | failed | cancelled
```

`authorized` 只表示当前 seam 返回 exact authorized task，不表示 workflow 创建了
cap。生产默认 seam 不可用时保持 `accepted` 或进入 `blocked`，且零副作用。

每个 state transition 继续使用单 SQL CAS。Store 必须验证 legal edge，禁止任意
字符串状态跳转。

## 6. Provider mutation reconciliation

### 6.1 第一次执行

一个 `create_change_request` callback 内：

1. mint exact repository + `change_request_write` token；
2. fresh-read base ref，验证 expected base SHA；
3. fresh-read deterministic head ref；
4. head 不存在时创建 ref；存在时验证可安全复用；
5. 根据 change digest 创建 blob/tree/commit；
6. 以 non-force update 推进 deterministic head；
7. 查询 exact `head + base` 的 open PR；
8. PR 不存在时创建；存在时规范化并返回；
9. callback 返回前丢弃 token。

### 6.2 Crash/retry

必须覆盖下列 crash windows：

- commit 创建后、head 更新前；
- head 更新后、PR 创建前；
- PR 创建成功后、workflow fact 落库前；
- facts 落库后、state CAS 前；
- observation HTTP 成功后、snapshot 落库前。

恢复原则：

- deterministic ref 是远端 mutation identity；
- exact `head + base` 是 PR reconciliation identity；
- workflow fresh-read provider facts，不因本地缺 receipt 重复 POST；
- 不使用 PR title/body 作为 identity；
- 不 force push；
- 发现多个匹配 PR 或 branch provenance 不一致时 fail closed。

### 6.3 Observation

PR 打开后，一个 observation tick：

1. `read_change_request`；
2. 使用 fresh-read `head_sha` 调 `list_checks`；
3. 调 `list_reviews`；
4. 原子保存同一 tick 的 normalized facts；
5. 更新 `observations_current`。

重复 tick 只更新 snapshot revision/observed_at，不创建 mutation。空 checks 或空
reviews 是有效事实，不得伪造成通过或批准。

## 7. 错误与重试

### 7.1 Stable blockers

至少包括：

- `authorization_unavailable`
- `not_authorized`
- `workspace_not_ready`
- `workspace_identity_mismatch`
- `unsupported_workspace_change`
- `change_limit_exceeded`
- `base_sha_mismatch`
- `head_ref_conflict`
- `change_request_conflict`
- `installation_scope_mismatch`
- `provider_permission_denied`
- `provider_rate_limited`
- `provider_unavailable`
- `observation_incomplete`

错误呈现只包含 code、stage、retryable、attempt 和 safe metadata；不得包含 raw
response、token、authorization header、private key 或文件内容。

### 7.2 Retry policy

- deterministic validation/conflict：不可重试，进入 `blocked`；
- provider unavailable/rate limited：有界重试并尊重 safe retry metadata；
- crash/restart：从 durable state + remote reconciliation 恢复；
- checks/reviews 尚未出现：observation 可重试，不算 provider failure；
- 达到 deadline：明确 `blocked: observation_incomplete`。

## 8. 本地端到端验收

不访问真实 GitHub，不读取真实 secret。使用：

- fresh PostgreSQL test partition；
- 临时本地 bare repository + 真实 task-worktree provision；
- 显式 test-authorized execution backend；
- Req.Test 模拟 GitHub App JWT、installation、Git Data、PR、checks、reviews；
- 真实 workflow store/CAS/restart reconciliation。

主场景：

```text
accept task
→ authorize test task
→ prepare isolated workspace
→ test worker writes one bounded UTF-8 file
→ collect FileChange
→ mint scoped installation token
→ create/reconcile commit + branch + PR
→ read PR/checks/reviews
→ persist normalized facts
```

重复完整执行两次，断言：

- 一个 run；
- 一个 workspace provision；
- 一个 deterministic ref；
- 一个 effective remote commit；
- 一个 PR；
- 第二次允许 fresh-read，但没有重复 mutation；
- token mint count 符合 callback 数，token 不出 plugin；
- workflow facts 与 provider responses 一致。

故障注入至少覆盖：

- authorization unavailable 前零 side effect；
- workspace ready 前禁止 provider call；
- PR POST 成功但 receipt 丢失后的 reconcile；
- observation response 后 DB write 失败再恢复；
- branch collision；
- digest conflict；
- unsupported workspace change；
- GitHub 401/403/422/429/5xx 的稳定错误映射。

## 9. 实施切片

### Slice P1：Workflow legal state + authorization/execution seam

Owner：`ezagent_plugin_git_workflow`；表结构 migration 仅按仓库惯例落在
`ezagent_core/priv/repo_pg/migrations`，不改变 core runtime 或 CapBAC。

交付：

- fail-closed seam；
- deterministic branch；
- legal transition graph；
- typed facts schema/store；
- 无 public ingress/no-Cap/no-secret gates。

### Slice P2：Workspace change collection

Owner：`ezagent_domain_git` + `ezagent_domain_workspace`

交付：

- provider-neutral change port；
- ready-provision proof；
- bounded UTF-8 upsert collection；
- traversal/symlink/binary/delete/rename/mode/limit adversarial tests。

### Slice P3：GitHub branch/commit/PR idempotent reconciliation

Owner：`ezagent_plugin_github`

交付：

- ref create-or-reconcile；
- commit/head reconciliation；
- PR exact find-or-create；
- crash-window Req.Test；
- one-token-per-callback 与 secret gates。

P2 与 P3 可以在 P1 contract 冻结后并行。两者不得修改 workflow owner。

### Slice P4：Vertical runner + observation

Owner：`ezagent_plugin_git_workflow`

依赖：P1、P2、P3 已由 lead 集成。

交付：

- durable stage runner；
- workspace/change/provider orchestration；
- PR/check/review snapshots；
- retry/error presentation；
- local end-to-end test。

## 10. Lead review gates

每个 worker 必须从 handoff 写死的 refreshed integration SHA 新开独立 branch 和
linked worktree。worker 不修改 main worktree、不自行 merge main、不操作 canary。

Lead 按顺序：

```text
P1
→ P2 + P3（可并行）
→ integration review
→ P4
→ local E2E
→ PR CI
```

任何 worker 碰到以下事项必须停止：

- 需要新增 cap、推导 principal 或读取 `ctx.caps`；
- 需要把 token 交给 git/Agent/workspace；
- 需要修改 provider-neutral DomainGit action vocabulary；
- 需要 public ingress；
- 需要真实 GitHub mutation/canary；
- 需要跨 owner 修改而 handoff 未列出。

## 11. 完成声明

本设计完成后可以声明：

> Git Provider Plan E 本地 provider-owned PR loop 当前切片完成。

不得声明：

- Git Provider E2E 生产闭环完成；
- production authorization 已接线；
- managed Agent canary 已完成；
- GitHub merge loop 已完成；
- Kanban/socialware projection 已完成。
