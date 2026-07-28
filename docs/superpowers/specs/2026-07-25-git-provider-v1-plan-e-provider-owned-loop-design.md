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

> **2026-07-28：本段的「默认」是否仍是「唯一」，已改为待定排期决定——见 §3.4。**
> §3.3 更正后，原先支撑「恒 fail closed」的技术阻塞理由不再成立；
> `Unavailable` 作为**缺省**实现与作为**唯一**实现是两件事。

本地端到端测试注入显式 test-authorized backend。该 backend 只能通过依赖注入进入
测试调用，不得由 runtime env、route、ActionSet、CLI 或 Agent 参数启用。

### 3.2 当前明确禁止

**口径澄清（gaga 2026-07-28 确认）。** 本节原文继承自
`2026-07-24-git-provider-v1-plan-e-permission-neutral-pivot.md` §1 的
「不直接 issue/store cap」。按字面读，该禁令会让 main 上 **62 个 lib 文件**
以及 `.claude/skills/ezagent-developer/references/capbac.md` §10「我要授一个
capability」的标准 5 步清单全部违规——因此它显然不是字面意思。确认口径为：

> 禁的是**建授权体系、改 CapBAC 内部、造通配 fixture**；
> 不禁按 main 既有规范模式签发 **exact** cap。

据此，当前明确禁止：

- **建立第二套授权体系**：新的签发路径、新的 cap 存储、新的验证逻辑，或任何
  绕开 `Ezagent.Cap.Authorize.authorize/3` 的判定；
- **通配 cap**：任何 `instance: :any` / `behavior: :any` 维度。cap 必须五轴
  最小权限（concrete instance + workspace + 具体 action），否则 authz 变成
  空转、测试绿而什么都没验证；
- **凭空推导 principal**：caller/authenticated principal 必须来自持久化记录
  （`TaskBinding` / `WorkflowRun` 行），不得在执行时由代码构造或猜测。
  `{:admin, User.admin_uri()}` 只能作为**签发锚点**出现，永远不是 principal；
- **新建 `system://` principal**：`SystemPrincipal` 的北极星是 GENESIS-ONLY
  （`system_principal.ex` moduledoc：非 genesis principal 已全部消除，
  `system://bootstrap` 是仅存入口）。`capbac.md` §10.5 明写 "If you reach for a
  new `system://` principal, **stop** — that's a Decision-#154 review surface"；
- 修改 `EntityCaps`、`PresenterCaps` 或 CapBAC 内部；
- 把 `ctx.caps` 扩散出 seam backend：candidate set 只在 backend 内部组装并随
  单次 dispatch 消亡，不得进入 workflow 其它模块、持久化行、事件或日志
  （backend 内部构造 `%Invocation{}` 是 main 62 个站点的规范做法，不在禁列）；
- public route、controller、ActionSet registration、CLI、Mix task 或 agent tool；
- workflow 直接依赖 GitHub plugin；
- token、authorization header、private key、installation id 或 raw provider body
  进入 workflow rows、events、logs、errors、workspace 或 Agent。

**main 的规范模式**（`retirement_sweeper.ex:99-118` 等 62 处同形）：

```elixir
admin  = Ezagent.Entity.User.admin_uri()          # 签发锚点，非 principal
caller = <从持久化记录读出的 principal URI>        # 绝不推导
{:ok, cap} = Ezagent.Cap.issue_for_action({:admin, admin}, caller, action_target)
Invocation.dispatch(%Invocation{
  ctx: %{caller: caller, authenticated_principal: caller,
         caps: MapSet.new([cap]), ...},
  origin: :trusted_internal
})
```

替换 backend 不得改变 workflow state、idempotency key 或 provider facts schema。

### 3.3 与 main 权限收敛的关系

§3.1 seam 生产默认 `authorization_unavailable`，不是权宜绕过，而是 main 上真正的
cap 收敛链路尚未到达可接入点。

**本节 2026-07-28 重写。** 原文有三处事实错误，逐条更正如下（复核基线
`origin/main@4c8b654f0`）。

**① 授权判定链路已经存在，不是「尚未到达可接入点」。**
`Ezagent.Cap.Authorize.authorize/3`（#1493，**2026-07-21**，即本设计写成之前）
已是单一授权 chokepoint，三道门：

1. **Principal gate** — holder 的 caps 由 `AuthorityLoader` 独立加载，
   **绝不取自 candidate_caps**；空集 → `{:error, :holder_revoked}`，fail closed；
2. **Target gate** — 每个候选对目标**当前 active authority row** 现读验证
   （`Authority.verify_against_current/3`，签名 + generation）；未签名、被篡改、
   被改指向、旧 generation 的候选一律丢弃；
3. **Shape match**。

cap 签名机制 #1457 更早（2026-07-18）。因此 `ctx.caps` 是**候选集**而非权限来源：
自带一个未真实签发、或库中已失效的 cap 授权不了。原文「V2 落地前不存在可接入的
真实 authorization 语义」判断过强。

**② C4–C7 已合。** #1579（**2026-07-26**）完成 actor-framework 抽取，
`Invocation`/`Cmd`/`Kind.Runtime` 已物理迁入 `apps/ezagent_actor`。原文的
「C4–C7 待迁」在本设计写成次日即失效。

**③ CALLER_IDENTITY 不再是未验证假设。** main 的规范模式（§3.2 末尾代码块，
`retirement_sweeper.ex:99-118` 等 62 处同形）就是：**principal 从持久化记录读出，
admin 仅作签发锚点**。`TaskBinding.credential_owner_uri` /
`Entity.GitTaskAccess.grantee_uri` 正是这个角色，与既有实践一致，无需另做设计。

**仍然未落地的是 V1/V2 本身**（`EzAgentActor.call/4` 在 main 上不存在）。V2 的
改动面是**候选集从哪来**，不是判定逻辑——convergence design §3 原文：
"V2 changes where the CANDIDATES come from, not the decision logic"。

**因此 seam 的存续理由改写：**

- ~~旧理由~~：main 上不存在可接入的真实授权语义，故生产恒 fail closed。**已作废。**
- **新理由**：V2 落地时，今天按 main 规范模式接线的 workflow 需要与其余 62 个
  站点**一起**迁移候选集来源。seam 把这个迁移面收敛在单一模块内。这是**降低
  迁移成本**，与「等待可用性」是两回事——后者会得出「V1 必须 dormant」，前者
  不会。

与 Feishu 绑定（B1 #1568 / B2 #1547）的类比据此收窄：相同点是都用 seam 收敛
迁移面；**不同点是 Git Provider 的授权接入不再有技术阻塞**。是否解除
§3.1「生产默认恒 `authorization_unavailable`」是独立的排期决定，见 §3.4。

### 3.4 待定：是否解除生产端的 fail-closed 默认

**状态：未决（2026-07-28 提出）。** §3.3 拆掉了原来的技术阻塞理由，于是
§3.1「生产默认实现始终返回 `:authorization_unavailable`」变成一个**排期选择**
而非必然：

| | 保持 `Unavailable` 为唯一实现 | 增加真实 production backend |
|---|---|---|
| production | 真死路（compile-time 烘死，四条 runtime 翻转路径均有测试证否） | 按 §3.2 规范模式接线 |
| V1 状态 | dormant，PR 标 `blocked: auth-convergence` | 可真实接线 |
| P4d 的 E2E | 证明「**除授权之外**的一切」 | 真端到端 |
| V2 迁移风险 | 无（届时一并实现） | 与 main 其余 62 站点同级，非额外风险 |

对「Git Provider E2E 测试」这个目标而言，左列恰好证明不了授权那一段。

**无论选哪列，P4a 的交付物不变**：`%AuthorizedTask{}` 的四字段
（policy / task_access_uri / task_uri / generation）正是 §3.2 规范模式所需的
输入，`Unavailable` 从「唯一实现」降为「缺省实现」是增量而非重写。故此决定
不阻塞 P4a，可在 P4b/P4d 之前任意时点作出。

**若选右列，必须同时满足：**

- cap 五轴最小权限，禁止任何 `:any` 维度（§3.2）；
- principal 取自 `TaskBinding` / `WorkflowRun` 持久化行，不得推导（§3.2）；
- 端到端测试须包含否定断言——wrong receiver / wrong workspace / wrong instance
  / wrong action 均返回 `:missing_cap`，照抄
  `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs:106-146`
  的四条。缺了这些，测试只证明「cap 存在即通过」，不证明 authz 生效。

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

**冻结的是 provider-facing adapter callback 集合**（`Ezagent.DomainGit.Adapter`
的 `@callback`）：

- `resolve_repository`
- `create_change_request`
- `read_change_request`
- `list_checks`
- `list_reviews`

V1 不新增任何 adapter callback，**尤其不新增 merge action**——真实 merge 由
human/lead 在 GitHub 执行（§2.3）。

`Ezagent.ActionSet.GitTaskAccess` 现有的 action 集合是上述 5 个 adapter callback
加上两个 workspace action：

- `provision_workspace`（已接入 `WorkspaceProvisionPort`/`WorkspaceProvisionRegistry`，
  Slice P2 应复用而非新建）
- `cleanup_workspace`（同上）

**ActionSet 一侧不受上述冻结约束。** Slice P2 若需要 workflow 调用其
workspace-change port，应按 `provision_workspace` 的既有形状新增一个
provider-neutral 的 workspace action（例如 `collect_workspace_changes`），由
ActionSet 承担策略校验与 receiver 授权，而不是让 workflow 绕过 ActionSet 直连
port。新增此类 workspace action **不算**违反本节冻结——冻结针对的是 provider
adapter 契约，不是 ActionSet 的 workspace 面。

> 措辞订正 2026-07-26：本节原先把 7 个 GitTaskAccess action 混在一句"冻结现有
> adapter action vocabulary"里，字面读法会禁止任何新增 action，与 §4.2 要求
> workspace owner 提供 change-collection 能力相冲突。上文按原意拆分了两者。

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

**步骤 5 的 commit 必须是确定性的**（补充 2026-07-27）。blob 与 tree 天然内容
寻址、重复创建幂等；但 commit 不是——GitHub 在 `author`/`committer` 日期缺省时
填入当前时间，于是同一份内容每次重试都得到**不同的 commit sha**。这直接违反
§6.2 的第一个 crash window：ref 尚停在 base 时重试，会产生第二个孤儿 commit。

因此创建 commit 时必须显式传入 `author` 与 `committer`（含 `date`），且该 date
在同一 run 的重试之间不得变化。这样 `tree + parents + message + author +
committer` 全部确定，commit sha 成为内容的纯函数，重试得到同一个 sha，窗口 1 真
正幂等。

**该 date 必须是 `git_workflow_runs.inserted_at`——run 被 accept 那一刻的真实
时间**（订正 2026-07-27）。它同时满足四个条件：accept 时写入一次、重试永不改变
（`Store.upsert_facts` 的 update 子句显式排除 `inserted_at`）、是真实挂钟时间、
且每个 run 不同。

不接受的替代方案，及其各自缺的那一条：

- 创建 commit 时读挂钟 —— 破坏确定性，正是本条要修的问题；
- 固定常量 —— 所有 commit 时间戳相同，Git 历史失去可读性；
- 从 idempotency key 哈希推导 —— 确定但**产出虚构日期**（32 位无符号数当 Unix
  秒，范围 1970–2106，实测 58% 落在未来，典型值 2085 年），reviewer 会认为工具
  损坏。

传递方式：`CreateChangeRequest` 携带一个 provider-neutral 的 commit date 字段，
**必填、无默认值**——缺失即 fail，好过静默使用一个编造的时间。构造该 request 的
是 workflow（Slice P4），它从自己的 run 行读取 `inserted_at` 传入。adapter 只使
用该值，不自行推导时间。

（本节冻结的是 §4.3 的 adapter callback 集合，不含 DomainGit 值形状，故为
`CreateChangeRequest` 增加 provider-neutral 字段不违反冻结。）

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
- `no_changes_collected`

错误呈现只包含 code、stage、retryable、attempt 和 safe metadata；不得包含 raw
response、token、authorization header、private key 或文件内容。

**`no_changes_collected` 语义**（补充 2026-07-26）：task worktree 收集到零个
change 时返回该码。它是**不可重试的 blocker**，不是 provider 失败——重跑同一个
generation 只会再次得到空 diff。V1 不为空 diff 创建 PR：没有 commit 的 PR 对
reviewer 无意义，且会污染 §5.3 的 facts（`change_digest` 无值可填）。run 停在
`blocked` 并保留该码，由 operator 判断是任务本身无需改动、还是 Agent 未产出预期
变更。P4 的 retry classification 据此把它归入"deterministic validation/conflict：
不可重试"一类（§7.2 第一条）。

> 该码由 Slice P2 规划期发现：§7.1 原清单未覆盖空 diff 这一必然会发生的正常路径
> 结果。P2 的 collector 负责产出它，P4 负责按上述语义分类。

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

`ezagent_plugin_git_workflow` 已有 `workflow_run.ex` 状态词表，产出于更早的 E0-E9
wave 计划（`docs/superpowers/plans/2026-07-24-git-provider-v1-plan-e-simplified-implementation.md`
Slice E2；该计划的 E3-E9 覆盖 managed-Agent sidecar、check/review 门禁、human-merge
确认、Kanban 投影、canary，均不在本 V1 范围）。§5.4 的状态机取代该词表——P1 落地时
整体替换，不与旧词表并存；无需数据迁移（dev 阶段、`git_workflow_runs.status` 无 DB
CHECK 约束）。若 E0-E9 剩余部分（尤其 E7 Kanban 投影、E9 canary）在 V1 之后仍要做，
是独立的后续规划决定，不在本设计断言范围内。

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

- 需要**通配 cap**（任何 `:any` 维度）、需要**凭空推导 principal**、需要新建
  `system://` principal，或需要把 `ctx.caps` 带出 seam backend；
  （2026-07-28 口径更新：按 §3.2 规范模式签发 **exact** cap **不**触发停止条件）
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
