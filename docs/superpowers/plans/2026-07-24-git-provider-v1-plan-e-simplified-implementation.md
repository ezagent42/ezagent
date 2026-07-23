# Git Provider V1 Plan E 简化实施计划

> **For agentic workers:** 每个切片必须先加载并遵循 `executing-plans`、
> `test-driven-development`、`ezagent-developer`、`project-discussion-esr-ng`、
> `elixir-phoenix-helper`、`dev-together` 与 `verification-before-completion`。
> Worker 只实施 handoff 明确分配的切片；不得自行扩展跨层依赖、CapBAC 豁免或
> canary 权限。

**目标：** 以 GitHub App 为唯一 repository-operation 认证模型，把 Plan E 拆成
可独立 review、拒绝、回滚和验收的 E0–E9 切片，最终证明真实 managed Agent 在
隔离 worktree 中经批准的 `GitTaskAccess` action 创建 PR，系统 fresh-read CI、
review 和 merge 事实，并由 Kanban 只投影已确认事实。

**架构：** workflow plugin 只持久化 non-secret intent、状态转换和 provider-neutral
事实；Git domain 持有 provider-neutral policy/action vocabulary；GitHub plugin
独占 GitHub App JWT、installation resolution、operation-scoped token 和 Req HTTP；
Kanban 只消费受治理的 workflow facts，不依赖 GitHub plugin，也不发 GitHub HTTP。
跨 PostgreSQL、Kind runtime、Cap store、workspace 和 Agent lifecycle 采用 durable
stage + 幂等 reconciliation，不伪造跨系统原子事务。

**技术栈：** Elixir/OTP、Ecto/PostgreSQL、Ezagent Kind/CapBAC/ActionSet、
`Ezagent.DomainGit.Adapter`、Req/Req.Test、Phoenix umbrella release、declarative
plugin registration、socialware manifest seed、skills seed。

**批准设计：**
`docs/superpowers/specs/2026-07-24-git-provider-v1-plan-e-simplified-execution-amendment.md`

**计划基线：** `integration/git-provider-v1-plan-e` @
`6685ec567de195ffed66b1d4311df2920b173da8`，已合入
`origin/main` @ `53da027438cd701dc6825289e1dc9513dbeea027`。

---

## 0. 全局门禁

### 0.1 分支与 worktree

- 受管控主 worktree `/home/huangjiajia/ezagent` 固定 `main`，所有 worker 只读。
- 每个切片从 lead handoff 写死的 SHA 创建独立 linked worktree 和独立分支。
- worker 不向 `main` merge、不 push、不开 PR；return 后由本 integration session
  review、验收并按依赖顺序集成。
- 旧 A/A2/H/H2 分支只作 forensic evidence，禁止 merge、rebase 或 cherry-pick。
- worker 开始时必须回报 repo、绝对 worktree、branch、base SHA 和
  `git status --short`；return 时再次回报这些坐标。

### 0.2 不可变安全边界

1. Git domain/provider interface 保持 provider-neutral；不得加入
   `installation_id`、App private key、OAuth token 或 GitHub response shape。
2. GitHub App private key、client secret、webhook secret 和 installation token
   只存在于 GitHub plugin 可信回调栈或 runtime secret reference。
3. managed Agent、prompt、card、run、event、snapshot、日志和 evidence 均不得得到
   secret 本体。
4. Agent Git 操作只能经 exact `GitTaskAccess` action surface；禁止 `gh`、raw
   HTTP、raw RPC、runtime cookie 或任意 provider token 参数。
5. sidecar 启动前必须已有隔离 `project_cwd`、exact worker principal 和 strict
   verified worker authority。
6. task claim 只写 `accepted` intent；不得 spawn policy、clone/worktree、spawn
   Agent、启动 sidecar或调用 provider。
7. V1 不缓存 installation token：无 ETS、常驻 GenServer state、process
   dictionary、workflow persistence 或跨 callback reuse。
8. V1 不提供 provider merge action；human/lead 在 GitHub merge，系统只 fresh-read
   `merged`。
9. Kanban 不依赖 GitHub plugin，不创建 GitHub HTTP client，不接受 caller-supplied
   Git status 作为事实。
10. E9 前不部署、不读取 secret、不发真实 GitHub mutation、不操作 canary。

### 0.3 Worker 测试规则

每个 worker 按 TDD 顺序执行：

1. 先写一条失败的 public-contract 或 invariant test；
2. 运行该测试并保存失败摘要；
3. 写最小 production code；
4. 运行 focused app tests；
5. 运行相关 architecture/invariant tests；
6. return 前运行：

Wave 1 的精确命令分别为：

```bash
# E1
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e1 mix ci.fast
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e1 mix precommit

# E2
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 mix ci.fast
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 mix precommit
```

后续 handoff 按切片写死 `plan_e_e3` 至 `plan_e_e9`，worker 不自行复用他人的
PostgreSQL test partition。

`mix precommit` 是仓库完成门；`mix ci.fast` 是快速静态与不变量门。若 full suite
因共享基础设施而无法运行，worker 不能自行宣布通过，必须带完整命令、退出码和
失败归因 return，由 lead 决定是否重跑。涉及 release、socialware 或跨 app wiring
的切片还必须由 lead 在集成分支运行：

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_lead mix ci.local
```

---

## 1. 交付波次与依赖

| Wave | 切片 | 可并行性 | Lead 验收门 |
|---|---|---|---|
| 0 | E0 operator readiness | 可与 E1/E2 准备并行；不接触 secret 本体 | GitHub App 坐标和权限审计项齐全 |
| 1 | E1 operation-scoped credential；E2 durable intent + CAS | E1/E2 从同一 SHA 并行 | 两者分别验收；禁止交叉 cherry-pick |
| 2 | E3 workspace → worker → authority | 仅 E2 集成后 | `authority_ready` 前无 sidecar |
| 3 | E4 managed Agent create PR vertical slice | E1+E3 集成后，单线推进 | 首个真实 action-path 集成证明 |
| 4 | E5 checks/reviews；E6 external merge confirmation | E5 后才 E6 | 观察事实闭合且无 merge action |
| 5 | E7 Kanban projection；E8 skill/socialware | E7 的契约先于 E8；实现可在契约冻结后并行 | 无 plugin-to-plugin GitHub 依赖 |
| 6 | E9 integration/deploy/canary | E0–E8 全绿后 | 真实 managed Agent 闭环证据 |

**节奏：** Wave 1 只派 E1/E2。E2 验收集成后派 E3；E1 与 E3 都验收集成后才派
E4。E4 是继续投资的硬门：若真实 action path 无法建立，暂停 E5–E8，先修 E4，
不得用 mock observation 或 UI projection 掩盖。

---

## 2. Owner surface

| Slice | Owner app | 允许主要改动 | 明确禁止 |
|---|---|---|---|
| E0 | deployment/config docs + GitHub plugin config | `config/runtime.exs`、GitHub config validation、operator runbook | secret value、OAuth fallback |
| E1 | `ezagent_plugin_github` | installation mint、adapter profile selection、Req.Test | Git domain、workflow、Kanban |
| E2 | 新 `ezagent_plugin_git_workflow` + core migration/release wiring | binding、intent、run schema/store、claim action | workspace/worker/policy/provider |
| E3 | workflow plugin | runner/reconciler、workspace/worker/authority stage | GitHub HTTP、Kanban |
| E4 | workflow plugin + integration test wiring | sanctioned action dispatch、confirmed PR fact | adapter direct-call product path |
| E5 | workflow plugin | observation tick、confirmed check/review facts | unbounded poll、raw response storage |
| E6 | workflow plugin | external merge wait/fresh-read | merge/submit-review action |
| E7 | Kanban + approved provider-neutral fact seam | projection adapter、idempotent card update | GitHub dependency/HTTP |
| E8 | socialware/skill seed owner | manifest、skill orchestration、registration tests | `gh`/secret refs in prompt |
| E9 | integration/docs/deploy | release gates、operator runbook、redacted evidence | pre-gate canary |

任何切片发现必须修改 owner 表之外的 app，先停止并向 lead 提交：
“缺失 seam + 最小新依赖 + provider-neutral 证明 + CapBAC 影响”。未获书面确认不得改。

---

## 3. E0 — GitHub App migration 与 operator readiness

**目标：** 在真实 mutation 之前，证明部署配置指向 GitHub App，目标 repo 已安装
App，权限为最小集合，且所有 secret 只以 runtime reference 存在。

**拟改文件：**

- `config/runtime.exs`
- `apps/ezagent_plugin_github/lib/ezagent_plugin_github/config.ex`
- `apps/ezagent_plugin_github/test/ezagent_plugin_github/config_test.exs`
- `docs/runbooks/git-provider-v1-plan-e-github-app.md`

**步骤：**

1. 写 config test，区分 missing App config、missing OAuth identity config 和
   malformed private key；错误只含配置 key/env var 名，不含值。
2. 把 production GitHub App 配置集中到 `runtime.exs` 的 runtime reference，删除
   会让旧 OAuth App credential 被 repository adapter 当 fallback 的路径。
3. 写 operator runbook，固定以下 non-secret 输入：
   `app_id`、installation/account reference、selected repository、base branch、
   head namespace、required checks、reviewer、merge lead、canary user/workspace/
   agent/task/card。
4. runbook 只允许 operator 在部署 secret backend 配置 private key/client
   secret/webhook secret reference；证据记录“reference 已解析/未解析”，不打印值。
5. 写配置 sentinel test，扫描异常、inspect 和日志路径，确保配置错误不回显 PEM、
   client secret 或 webhook secret。

**封闭 DoD：**

- [ ] GitHub App config 缺失与旧 OAuth credential 均 fail closed；proof：
  `config_test.exs`。
- [ ] operator checklist 枚举 App 安装、selected repo、permission、review/merge 和
  canary 坐标；proof：runbook review。
- [ ] tracked files 无 secret 本体；proof：secret sentinel scan + lead review。
- [ ] 不发生 GitHub mutation；proof：该切片无 canary/HTTP evidence。

**预计：** 1 worker，0.5–1 AI 编程日，约 2–4 个文件、100–220 LOC。

---

## 4. E1 — operation-scoped GitHub App installation credential

**目标：** 每个 `DomainGit.Adapter` callback/tick 为 exact repository 和 closed
permission profile mint 一次 installation token，在该 callback 的有限 HTTP 批次
复用，返回前丢弃；完全删除共享 cache。

**拟改文件：**

- `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex`
- `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex`
- `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex`
- 新建
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/installation_permissions.ex`
- `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_installation_test.exs`
- `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs`
- 新建
  `apps/ezagent_plugin_github/test/architecture/operation_scoped_credential_test.exs`

**冻结 public/internal contract：**

```elixir
@type permission_profile ::
        :metadata_read
        | :change_request_write
        | :change_request_read
        | :checks_read

@spec token_for_operation(
        Ezagent.DomainGit.RepositoryRef.t(),
        permission_profile(),
        keyword()
      ) :: {:ok, String.t()} | {:error, atom()}
```

该函数是 GitHub plugin 内部可信 seam，不得注册为 ActionSet/Behavior/tool，也不得
被 workflow、Kanban 或 Agent 直接调用。profile 由 `GitHubAdapter` callback 静态
选择，不从 `ctx`、action args、prompt 或 card 读取：

```elixir
resolve_repository       -> :metadata_read
create_change_request    -> :change_request_write
read_change_request      -> :change_request_read
list_checks              -> :checks_read
list_reviews             -> :change_request_read
```

mint 请求必须包含 exact repository 与 profile permission map：

```elixir
%{
  repositories: [repo_name],
  permissions: InstallationPermissions.for!(:change_request_write)
}
```

该请求/响应契约以 GitHub 官方
[`Create an installation access token for an app`](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app)
为外部 source of truth；官方示例明确支持 `repositories` + `permissions` 限定，
201 response 包含 `repository_selection`、`repositories`、`permissions` 与
`expires_at`。

若 GitHub 的 response 中 `repository_selection`、`repositories`、`permissions`
或 `expires_at` 缺失、畸形或比请求更宽，在第一次 repository HTTP 前返回
`{:error, :installation_scope_mismatch}`。不要为此增加 cache fingerprint。

**步骤：**

1. 改写 installation tests，使它们先证明：
   exact repo body、exact permissions、scope mismatch fail closed、两个 callback
   mint 两次、一个 create-PR callback 的有限 HTTP 批次只 mint 一次。
2. 删除 `GitHubInstallation` 的 Agent child、ETS table、`child_spec/start_link`、
   `put_cached_token/3`、expiry refresh 和 account-wide key。
3. 实现 closed `InstallationPermissions.for!/1`，只有上表 profiles。
4. 实现 `token_for_operation/3`：
   App JWT → exact repo installation → exact repo token mint → strict response
   validation。只返回 adapter 当前调用栈需要的 token。
5. 修改 adapter，每个 callback 只获取一次 token，然后把该 token传给 callback
   内部的有限 Req 批次；禁止每个 HTTP request 单独 mint。
6. 加结构 gate，证明 GitHubInstallation 无 ETS/Agent/process dictionary、
   无 public cache seeding，token seam 未进入 action vocabulary。
7. 加 sentinel tests：token 不进入 adapter result、mapped error、Logger、Application
   env、persistent term 或 workflow state。

**拒绝条件：**

- profile 由 caller 选择；
- token request 不限定单 repository；
- response scope 没有在 repository mutation 前验证；
- 为性能重新引入共享 cache/reservation/waiter/timer；
- adapter callback 间复用 token；
- GitHub plugin 之外新增 token consumer。

**封闭 DoD：**

- [ ] E1 必测七项全部自动化；
- [ ] `GitHubAdapter` 仍完整实现 provider-neutral `DomainGit.Adapter`；
- [ ] operation-scoped mint count 由 Req.Test 证明；
- [ ] no-cache/no-agent/no-token-action architecture gate 通过；
- [ ] focused tests、`mix ci.fast`、`mix precommit` 通过。

**预计：** 1 worker，1–1.5 AI 编程日，约 7 个文件、250–450 LOC（含测试）。

---

## 5. E2 — durable workflow intent 与原子 CAS

**目标：** 建立最小 workflow owner app。授权 claim 只创建/返回同一条
`status: :accepted` 的 non-secret intent；并发 claim 和状态转换依赖 PostgreSQL
唯一约束/单语句 CAS，而不是 `get → update`。

**拟改文件：**

- 新建 `apps/ezagent_plugin_git_workflow/mix.exs`
- 新建
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/application.ex`
- 新建
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/task_binding.ex`
- 新建
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_run.ex`
- 新建
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex`
- 新建
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/task_intake.ex`
- 新建
  `apps/ezagent_plugin_git_workflow/lib/ezagent/behavior/git_workflow.ex`
- 新建
  `apps/ezagent_core/priv/repo/migrations/20260724010000_create_git_workflow_intents.exs`
- 修改 `mix.exs` release applications
- 修改 `apps/ezagent_web/mix.exs` 以启动 sibling plugin
- 新建 app tests 与 architecture tests

**数据契约：**

`git_workflow_bindings` 只存 governed coordinates：

- binding id/generation；
- exact workspace URI；
- task/card receiver URI；
- credential owner URI；
- canonical provider-neutral `RepositoryRef` fields；
- allowed base/head policy；
- enabled/disabled 与 timestamps。

`git_workflow_runs` 至少存：

- `id`；
- `binding_id`、binding generation；
- stable external task id；
- `authenticated_principal_uri`；
- `status`，初始 `"accepted"`；
- `state_version`，初始 `1`；
- idempotency key/input digest；
- non-secret intent payload；
- `last_error_code`、timestamps。

唯一键由 `(binding_id, generation, external_task_id, input_digest)` 构成。同一输入并发
claim 返回同一 run；同 task 不同 digest 返回 closed conflict，不静默覆盖。

状态 CAS 的 SQL 语义必须等价于：

```elixir
from(r in WorkflowRun,
  where: r.id == ^run_id and r.state_version == ^expected_version
)
|> Repo.update_all(
  set: [status: next_status, state_version: expected_version + 1]
)
```

更新行数必须为 1；0 行时 fresh-read，区分 exact retry、stale version、terminal
conflict。不得用 GenServer 串行化替代数据库正确性。

**claim 契约：**

```text
reviewed ingress authenticated_principal
→ Cap.authorize/3 验当前 holder 对 claim receiver 的 authority
→ load active governed binding
→ validate canonical intent
→ insert-or-load accepted run
→ return normalized run identity
```

claim 中禁止调用 `Kind.spawn`、`Cap.issue`、cap store、workspace、Agent、sidecar、
adapter、Req 或 Kanban。

**步骤：**

1. 先写 migration/schema test，证明约束、URI round-trip 和 secret fields absence。
2. 写真实 PostgreSQL concurrency tests：
   20 个并发相同 claim 只产生 1 run；20 个同 version CAS 只有 1 个成功。
3. 写 authority tests：
   missing `authenticated_principal`、revoked holder、no matching cap 均零 run side
   effect，并保持 #1503 的稳定错误语义。
4. 实现 binding validation 和 sanctioned admin authorization。binding registration
   不接受 credential/token/installation id 字段。
5. 实现 `Store.claim/1` 与 `Store.transition/4`；所有 idempotency/conflict 决策
   由数据库结果驱动。
6. 实现最小 GitWorkflow ActionSet：只暴露 binding 管理和 claim/read-run 所需
   actions；不暴露“materialize all authority”或 provider action。
7. 增加 architecture gate：
   workflow app 不依赖 GitHub/Kanban/socialware plugin；claim call graph 无
   workspace/worker/provider side effect。
8. 完成 umbrella/release wiring 与 declarative plugin registration test。

**拒绝条件：**

- claim 创建 workspace/worker/policy/cap；
- 用内存锁/Agent/ETS 保证 claim 或 CAS；
- 将 token/credential value/raw provider data存入 binding/run；
- workflow plugin 直接依赖 GitHub 或 Kanban plugin；
- 为复用旧 A 分支而保留 `PolicySet.materialize/3` claim-time 语义。

**封闭 DoD：**

- [ ] unauthorized claim 零副作用；
- [ ] authorized claim 只产生 `accepted` intent；
- [ ] concurrent claim 与 CAS 由真实 PostgreSQL test 证明；
- [ ] run schema 没有 secret/provider-private 字段；
- [ ] release/plugin wiring tests 通过；
- [ ] focused tests、`mix ci.fast`、`mix precommit` 通过。

**预计：** 1 worker，1.5–2.5 AI 编程日，约 14–18 个文件、600–950 LOC（含 migration
与测试）。这是 Wave 1 较大的任务，但边界比旧 A 明显收窄。

---

## 6. E3 — isolated workspace → exact worker → authority_ready

**依赖：** E2 已验收并集成。

**目标：** runner 从 durable `accepted` run 分阶段推进；只有 workspace、worker 和
strict verified exact authority 都确认后才进入 `authority_ready`。

**拟改文件：**

- `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/runner.ex`
- `.../reconciler.ex`
- `.../workspace_stage.ex`
- `.../worker_stage.ex`
- `.../authority_stage.ex`
- `.../policy_obligation.ex`
- 对应 tests；按实际使用增补 workflow app 的 domain dependencies

**步骤与转换：**

1. `accepted → workspace_ready`：经现有 owner-gated
   `WorkspaceProvisionPort`，保存 canonical isolated `project_cwd` reference；
   验证 cwd 属于该 task/generation。
2. `workspace_ready → worker_ready`：从
   `(workspace, binding_id, run_id, generation)` 确定性派生 exact worker URI；
   幂等创建/确认 managed worker principal。
3. `worker_ready → authority_ready`：构造 exact `GitTaskAccess`，走 sanctioned
   issue → store → strict verify；run 只保存 policy URI/digest/result，不保存 cap
   token。
4. 每一步先持久化 obligation/attempt，再执行外部 lifecycle side effect，再
   fresh-read 验证并 CAS 接受结果；crash 后 reconciler 从 durable status 重试。
5. orphan 只由 runner/coordinator cleanup authority 处理；author Agent 不得得到
   cleanup action。

**测试：**

- 每阶段 deterministic/idempotent；
- exact worker 不存在时不能 self-store worker cap；
- issue 成功/store 失败、store 成功/verify 失败均可恢复；
- `authority_ready` 前 sidecar start spy 为 0；
- stale generation/policy digest fail closed；
- crash/restart 不重复已接受的 side effect。

**封闭 DoD：** 状态逐段可恢复、strict verification 有真实 Cap store 证据、
sidecar ordering invariant 自动化、无 GitHub/Kanban 依赖。

**预计：** 1 worker，2–3 AI 编程日，约 10–15 个文件、700–1,100 LOC。

---

## 7. E4 — managed Agent create PR 首个纵向闭环

**依赖：** E1、E3 已验收并集成。

**目标：** 从 `authority_ready` run 启动 sidecar，把 exact task 交给 managed
Agent；Agent 只能经 sanctioned `GitTaskAccess.create_change_request` 创建 PR；
coordinator 随后经 `read_change_request` fresh-read 并持久化 normalized
`pr_open` fact。

**拟改文件：**

- workflow plugin 的 `agent_stage.ex`、`git_dispatch.ex`、`fact_store.ex`
- workflow runner 状态转换
- workflow integration tests
- Git domain/action surface 仅在发现缺失 provider-neutral seam 且 lead 批准时修改

**步骤：**

1. 以 `authority_ready`、exact `project_cwd` 和 worker URI 为 sidecar start
   precondition；缺一返回 durable blocker。
2. task payload 只含 canonical repository/ref/change request inputs 和 action URI；
   不含 adapter module、GitHub URL path 或 credential reference。
3. 由 Agent 调用 `GitTaskAccess.create_change_request`；workflow 不直接调用
   `GitHubAdapter`。
4. create result 先视为 candidate fact；coordinator 用受批准 observation authority
   调 `read_change_request` fresh-read。
5. 只有 normalized `state: :open`、exact head/base/repo 一致才 CAS
   `authority_ready → pr_open` 并写 immutable fact revision。

**自动化证明：**

- 从 accepted run 走完整 E2/E3/E4 seam，不直接插入中间状态；
- sidecar 在隔离 cwd 启动；
- Agent 无 token/raw HTTP/`gh`；
- adapter registry 使用 GitHub 实现但 workflow 不 compile-depend GitHub plugin；
- create response 未 fresh-read 时不能写 `pr_open`；
- retry 不创建第二个 PR，依赖 idempotency inputs/head ref 和 fresh-read reconcile。

**真实外部证据：** E4 代码阶段只用 Req.Test/受控 integration seam，不操作 canary。
真实 disposable repo 证据留到 E9。

**预计：** 1–2 workers 串行（owner + independent contract reviewer），2.5–4 AI
编程日。

---

## 8. E5 — CI 与 independent review observation

**依赖：** E4。

**目标：** 对已确认 PR 做 bounded observation tick；保存 normalized checks/reviews
事实，required checks 全部成功且 independent approval 满足后进入
`awaiting_external_merge`。

**实现约束：**

- 一个 tick 为 `read_change_request + list_checks + list_reviews` 的有界批次；
  每个 adapter callback operation-scoped mint，不跨 tick 留 token。
- 优先 webhook 唤醒 runner，poll fallback 为 `15s → 30s → 60s`，每次 60s 直到
  deadline；run 只存 next observation time/attempt/latency/rate-limit safe metadata。
- required checks 从 governed binding/config 来，不由 Agent 提交。
- author 自己的 approval 不计 independent review。
- facts 以 provider revision/observed_at 幂等，状态单调；过期 webhook 不能回退。

**拟改文件：** workflow `observation_tick.ex`、`check_policy.ex`、
`review_policy.ex`、fact schemas/migration、webhook-to-run wakeup seam 和 tests。

**DoD：** required check 集合闭合、review independence 自动化、bounded poll、
stale event 不回退、无 raw response/token persistence。

**预计：** 1 worker，2–3 AI 编程日。

---

## 9. E6 — human merge 与 fresh-read merged confirmation

**依赖：** E5。

**目标：** 状态停在 `awaiting_external_merge`，由 human/lead 在 GitHub 完成 merge；
系统只通过 fresh `read_change_request` 确认 exact PR `state: :merged`，再写
`merged_confirmed`。

**步骤：**

1. architecture test 冻结 author/coordinator action vocabularies均无
   `merge`/`submit_review`。
2. webhook 只唤醒，不直接宣称 merged。
3. fresh-read 必须核对 repo、PR id、head/base、merged state；closed-unmerged 进入
   blocker，不当作 merged。
4. merge SHA 若 domain normalized type 尚缺失，先提出 provider-neutral seam 给
   lead；不得在 workflow row 塞 GitHub-private map。

**真实外部条件：** independent reviewer 和 lead merge 权限；仍只记录主体 URI/用户
label 等非秘密坐标。

**DoD：** 无机器 merge path、webhook spoof 不能完成、closed != merged、fresh-read
confirmed fact 可重放幂等。

**预计：** 1 worker，1–1.5 AI 编程日。

---

## 10. E7 — Kanban confirmed-fact projection

**依赖：** E4–E6，先冻结 provider-neutral fact contract。

**目标：** Kanban 将 `pr_open`、checks/review、`merged_confirmed` 事实投影为 card
artifact/status；不查询 GitHub，不接收 Agent 自报 Git 状态。

**设计门：**

当前 Kanban `connectors.ex` 的 `register_pr` 只是 caller-supplied 纯数据。E7 不得
把它直接当 confirmed fact seam。实施前 worker 必须先给 lead 提交两种最小方案的
file:line 对比：

1. 复用既有 domain external-mirror/event seam；
2. 在 provider-neutral domain 层增加只读 `GitWorkflowFact` projection port。

Lead 只批准其中一个。不得建立 `kanban → github` 或 `workflow plugin → kanban
plugin` 编译依赖。

**实现后 DoD：**

- projection input 带 run id、fact revision、source receiver 和 confirmed marker；
- projector 验来源 authority/ownership，重复 revision 幂等；
- PR artifact 来自 confirmed fact，checks/review 未满足不投影 done；
- `merged_confirmed` 才允许最终 done；
- Kanban tree mutation 仍走 `Shared.commit/1` 与既有 owner/admin gate；
- architecture test 证明 Kanban 无 GitHub HTTP/client/dependency。

**预计：** 先 0.5 AI 日 clarify；确认后 1.5–2.5 AI 编程日。

---

## 11. E8 — agent skill orchestration 与 socialware registration

**依赖：** E4–E7 contract 已冻结。

**目标：** 发布可安装的 Plan E socialware/skill，使 Agent 只通过 sanctioned
workflow facade 完成 create PR、等待 CI/review、等待 human merge、投影事实的
编排；manifest 和 seed 走现有 deployment-level 三态 seed lane。

**拟改 surface：**

- 合适 owner app 下 `priv/socialware/<slug>/manifest.yaml`
- `apps/ezagent_web/priv/skills_seed/<ref>/SKILL.md` 或由既有 regen task 生成的来源
- socialware manifest/skill seed tests
- workflow facade 的 tool declaration/registration tests

**步骤：**

1. 先读取 `ezagent-socialware` skill 和当前 manifest/skill seed source of truth。
2. manifest 只声明已注册 ActionSet/tools/caps；不得自造 raw RPC。
3. skill 明确 workflow states、blocker 和 human merge handoff；禁止 `gh`/curl、
   token、credential ref、secret env 名称读取指令。
4. 用 `ManifestSeed/SkillSeed` 三态契约证明 clean deploy、matching existing、
   conflict existing；不得写 `$HOME` 或 runtime scan 未批准目录。
5. agent/session regression test 经真实 tool dispatch，而不是直接调用 workflow
   module。

**DoD：** manifest 可发布/发现/安装/使用；skill 从真实 registry 可见；agent tool
只有批准 surface；冲突 seed fail closed；无 secret/action vocabulary drift。

**预计：** 1 worker，2–3 AI 编程日。

---

## 12. E9 — integration、部署与真实 canary

**依赖：** E0–E8 全部验收集成。

**目标：** 在 disposable selected repository 上取得完整真实闭环证据。

**预 canary gate：**

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_final mix ci.local
mix release
git diff --check
git status --short
```

并由 lead 审核：

- release 中 workflow/GitHub/Kanban/socialware apps 均启动；
- GitHub App installation/permission audit 已完成；
- secret references 已由 operator 配置但未被 lead/worker读取；
- canary 用户、workspace、managed agent、task/card、repo、reviewer、merge lead
  坐标固定；
- cleanup 与中止 runbook 可执行。

**真实时序与证据：**

```text
Kanban task accepted
→ workflow run accepted
→ isolated project_cwd
→ exact worker principal
→ exact GitTaskAccess strict verified
→ managed Agent invokes create_change_request
→ GitHub PR visible
→ fresh-read pr_open fact
→ real CI completes
→ independent reviewer approves
→ human/lead merges in GitHub
→ fresh-read merged_confirmed
→ Kanban projection completed
→ worker/worktree/authority cleanup
```

每一步保存 redacted timestamp、run id、canonical URI、state version、provider fact
revision、PR URL/number、check names/conclusions、review outcome、merge confirmation 和
cleanup outcome。不得保存 Authorization header、JWT、installation token、private
key、client/webhook secret、raw DB dump 或完整 raw GitHub response。

**失败注入：**

- App 未安装/权限不足；
- CI failure；
- review 未批准；
- PR closed-unmerged；
- stale webhook；
- runner restart；
- duplicate dispatch。

每项必须停在可解释 blocker/failed state，不得误投影 done，重试不得创建第二 PR。

**最终 DoD：**

- [ ] 全部本地/CI/release gates 绿；
- [ ] 真实 managed Agent 闭环成功；
- [ ] human merge 边界有证据；
- [ ] Kanban 只投影 confirmed facts；
- [ ] cleanup 闭合；
- [ ] evidence redacted + secret scan 绿；
- [ ] lead 独立 review 后才宣布 Plan E 完成。

**预计：** 1 integration worker + lead/operator，1–2 AI 编程日，加 0.5–1 个实际
环境日用于 GitHub App 配置、CI、review 与 merge 等待。

---

## 13. 总工作量估算

以 AI 编程、多 worker、已有 Git domain spine 为前提：

| 范围 | 串行关键路径 | 可并行工作 |
|---|---:|---:|
| E0–E2 | 2–3 AI 日 | E0/E1/E2 可部分并行 |
| E3–E4 | 4.5–7 AI 日 | contract reviewer 可伴随，但实现串行 |
| E5–E6 | 3–4.5 AI 日 | E6 依赖 E5 |
| E7–E8 | 3.5–5.5 AI 日 | E7 contract 冻结后可并行 |
| E9 | 1–2 AI 日 + 0.5–1 环境日 | gate/evidence 可分工 |

**整体：** 约 14–22 AI 编程日工作量；按 2 个实施 worker 的安全并发节奏，日历时间
约 8–12 个工作日。若 E4 首个真实 action path 暴露新的 sanctioned seam 缺口，
增加 2–4 个工作日；不得用跨层 shortcut 压缩。

---

## 14. Lead review/集成协议

每个 return 按以下顺序验收：

1. 核对 worktree/branch/base/head/status；
2. 读取完整 diff，不以 worker 描述代替代码；
3. 对照该切片 closed DoD 逐项给出 pass/fail/evidence；
4. 重点审计 authority、secret、provider-neutral、sidecar ordering 和跨 app deps；
5. 在 worker worktree 重跑 focused tests；
6. 必要时由独立 reviewer 做 adversarial pass；
7. 只在无 blocker 时把 worker commit 集成到
   `integration/git-provider-v1-plan-e`；
8. 集成后重跑受影响 tests 与 `mix ci.fast`；
9. 更新 coordinator `subagents.md` 和 append-only `done.md`；
10. 只有依赖门满足后才发下一 wave handoff。

worker return 中的“完成”只是候选结果；`READY TO INTEGRATE` 由 lead 给出。

---

## 15. 当前派发动作

批准本计划后，只派 Wave 1：

- E1：`feat/git-provider-v1-plan-e-app-operation-credential`
- E2：`feat/git-provider-v1-plan-e-workflow-intent`

二者使用本计划 docs-only commit 的精确 SHA 为共同 base。E1/E2 return 之前不派
E3；E4 之前不派 E5–E8；E9 之前不操作 canary。
