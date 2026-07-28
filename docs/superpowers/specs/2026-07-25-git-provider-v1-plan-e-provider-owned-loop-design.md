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

~~生产默认实现始终返回 `:authorization_unavailable`~~
**（2026-07-28 gaga 决定解除，见 §3.4）**：生产接线一个真实 backend，
按 §3.2 的 main 规范模式取得授权；`Unavailable` 保留为 backend 缺失时的
**兜底**，仍在 workspace、filesystem、provider 和 Agent side effect 之前
fail closed。

任何 backend——真实的或兜底的——在返回 `{:error, _}` 时都必须零副作用：
不得已经建过 workspace、写过文件、发过 provider 请求或碰过 Agent。

本地端到端测试仍可注入显式 test backend。该注入只能通过依赖注入进入测试调用，
不得由 runtime env、route、ActionSet、CLI 或 Agent 参数启用。

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

### 3.4 已决：解除生产端的 fail-closed 默认（gaga 2026-07-28）

§3.3 拆掉了原来的技术阻塞理由，于是「生产恒 `authorization_unavailable`」
从必然变成排期选择。**决定：解除。**

理由是目标一致性——本设计服务于 Git Provider 的端到端验收，而保持死路的方案
恰好只能证明「**除授权之外**的一切」：

| | 保持 `Unavailable` 为唯一实现 | **已选：增加真实 backend** |
|---|---|---|
| production | 真死路 | 按 §3.2 规范模式接线 |
| E2E 覆盖 | 绕开 `authorize_receiver` / `allowed_actions` | 覆盖这两层 |
| V2 迁移风险 | 无（届时一并实现） | 与 main 其余 62 站点同级，非额外风险 |

#### 3.4.1 两层授权的分工（实施前必须理解）

真实 backend 会用 `Cap.issue_for_action({:admin, …}, caller, action_target)`
现铸 cap 再 dispatch——这是 main 62 处同形写法。**必须清楚它保证什么、不保证
什么**，否则会高估这层的强度：

| 层 | 回答的问题 | 把关处 |
|---|---|---|
| **cap** | 这是不是合法的框架内部流量？ | `Cap.Authorize.authorize/3` 三道门：principal 独立加载（吊销 → `:holder_revoked`）、对目标当前 authority row 现读验签名+generation、shape match |
| **`GitTaskAccess` policy** | 这个 grantee 能不能对这个仓库做这个动作？ | `authorize_receiver`（`caller == policy.grantee_uri`，`behavior/git_task_access.ex:337-356`）+ `action_allowed`（`action in policy.allowed_actions`，`entity/git_task_access.ex:336`）+ `validate_task_coordinates` / `validate_requested_head` |

cap 由代码现铸，因此**不**代表「operator 显式授权了这个 workflow」。Git
Provider 真正的业务授权在下面那层，它是持久的、per-task 的、显式声明
grantee + 允许动作 + 允许 head ref——解除之后，**这一层第一次被真正测到**。

#### 3.4.2 解除的具体形态（约束）

- **换的是 `Application.compile_env/3` 的缺省值**，不是让 prod config 指定
  backend。`architecture_test.exs` 那条「非测试 config 不得设 `:execution_seam`」
  的断言（含两种拼写）原样保留、必须继续通过；
- `Unavailable` 保留为兜底实现，不删除；
- principal 取自 `TaskBinding` / `WorkflowRun` 持久化行，不得推导（§3.2）；
- cap 五轴最小权限，禁止任何 `:any` 维度（§3.2）；
- **强制否定断言**：wrong receiver / wrong workspace / wrong instance /
  wrong action 均须被拒，照抄
  `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs:106-146`
  的四条。缺了这些，测试只证明「cap 存在即通过」，不证明 authz 生效；
- §10 的 operator gate **未解除**：真实 GitHub mutation / canary 仍需 operator
  批准。本设计的验收全部走本地 `Req.Test`，不碰真实 GitHub。

#### 3.4.3 对切片的影响

真实 backend 是**授权面**，需要独立的对抗性评审和上述否定断言，因此单独成片
（§9 的 P4b），不与 stage runner 混装。P4a 的交付物不受本决定影响。

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

#### 6.2.1 未关闭：ref-at-base 的 provenance 缺口（订正 2026-07-28）

`ezagent_plugin_github` 的 adapter 在 `github_adapter.ex` 记着一条 KNOWN
LIMITATION：deterministic ref 已存在**但仍停在 base** 时，adapter 没有任何
commit 可比对 provenance，因此分不清「这是我自己上次重试留下的」与「这是外部
在同名位置 planted 的」，两者都被当作可安全 resume。

**该缺口至今未关闭。** 此处订正一条此前的错误判断：Slice P4c 的实施计划与其
合并说明称「provider 调用前先落 `deterministic_head_ref` 关闭了这个缺口」——
不成立。P4e 在验收时查证：

- 全仓 `deterministic_head_ref` 只有**一处写**（`stage_runner.ex`），
  **零处读**用于判定；
- 它是**无条件写**的，因此记录的是「这个 ref **名字**归本 run」，而不是
  「这个 ref **是我创建的**」；
- 而 ref 名字本就由 `DeterministicRef.derive(allowed_head_namespace, run.id)`
  纯函数推导，两个输入都持久——**持久化它没有提供任何本来推导不出的信息**。

P4c 真正交付的是**写序**：facts 在第一次 provider mutation 之前落库。那是关闭
缺口的**必要条件**（没有它，恢复时连一个可查的锚点都没有），不是关闭本身。

关闭它需要一个具备判别力的事实，例如「本 run 创建 ref 时它指向的 sha」或一条
显式的 created-by-this-run 记录，并在 adapter 的 resume 分支上真正读取。那是
provider owner 与 workflow owner 之间的一次契约变更，属独立决定，不在 P4 范围。

P4e 留了一条明确标注的 characterization 测试（"a ref planted at base by someone
else is resumed onto — the gap P4c did NOT close"），使得将来真正关闭它时会有
测试变红，而不是悄无声息。

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

原文交付清单（durable stage runner / workspace-change-provider orchestration /
PR-check-review snapshots / retry-error presentation / local E2E）在 2026-07-28
按实际起点拆为五片。拆分依据是 P1–P3 在代码里**指名要 P4 关闭**的四个口子，
外加 §3.4 决定新增的授权面：

| 片 | 交付 | 依赖 |
|---|---|---|
| **P4a** 地基 | `%AuthorizedTask{}`（封闭无凭证）；`ExecutionSeam.invoke/3` dispatcher + 类型收紧；`Store.update_facts/2` 增量写；`Blocker` 全覆盖词汇 + 重试分类 + 无泄漏呈现 | 无。不跑任何东西 |
| **P4b** 授权面 | 真实 seam backend（§3.4.2 全部约束）；四条否定断言 | P4a |
| **P4c** stage runner | workspace → changes → provider 编排；逐阶段 facts + CAS；**provider 调用前先落 `deterministic_head_ref`**（补 §6.2 的 provenance 缺口） | P4b |
| **P4d** observation | observation tick + 快照 | P4c |
| **P4e** 本地 E2E | §8 全部主场景 + 8 项故障注入 | P4c、P4d |

四个被指名的口子（均为 P1–P3 作者在代码里写下的原话）：

- `execution_seam.ex` 声明了 `@callback invoke/3` 但从未接线 → P4a；
- 同文件 moduledoc「Provisional `term()` typing (deferred to Slice P4)」：真实
  backend 构造 authorized task 时必须把类型收紧成封闭无凭证形状 → P4a；
- `store.ex` `facts_to_row/2` 输出全部字段含 nil + `ON CONFLICT` 全列
  `EXCLUDED` ⇒ 分阶段增量写会把前一阶段的事实清成 NULL → P4a；
- `github_adapter.ex` KNOWN LIMITATION：ref 停在 base 时 adapter 无法区分
  「自己上次重试留下的」与「外部 planted 的」，指名要 workflow 的 durable
  facts（§5.3）给身份 → 机制在 P4a，写序在 P4c。**订正 2026-07-28：写序是
  必要条件，不是关闭；该缺口至今未关闭，见 §6.2.1。**

## 10. Lead review gates

每个 worker 必须从 handoff 写死的 refreshed integration SHA 新开独立 branch 和
linked worktree。worker 不修改 main worktree、不自行 merge main、不操作 canary。

Lead 按顺序：

```text
P1
→ P2 + P3（可并行）
→ integration review
→ P4a 地基
→ P4b 授权面        ← 独立对抗性评审：四条否定断言必须真的会红
→ P4c stage runner
→ P4d observation
→ P4e 本地 E2E
→ PR CI
```

P4b 是本设计唯一的授权面切片，须单独评审，不与 P4c 合并验收。

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
