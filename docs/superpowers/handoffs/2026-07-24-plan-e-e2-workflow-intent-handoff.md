# Handoff：Plan E E2 — durable workflow intent 与 PostgreSQL CAS

> **2026-07-24 supersession：** 本 handoff 的 authorization、public ActionSet 和
> release ingress 要求已由
> `2026-07-24-plan-e-e2a-permission-neutral-correction-handoff.md` 取代。当前只实施
> E2-A；E2-B 等 Allen/main authorization resume gate。其余 typed intent、
> idempotency、digest conflict、PostgreSQL CAS 和安全边界继续有效。

> **日期：** 2026-07-24 · **From：** Plan E lead · **To：** 独立 implementation worker
> **Tracking：** Git Provider V1 Plan E / E2 · **Base：**
> `integration/git-provider-v1-plan-e` @
> `e34b45c5a6d572180af0899d24b7ce05e4267c9e`
> **状态：** confirmed — 只建立 accepted intent + CAS；禁止实施 workspace/worker/policy/provider

## 0. Mission

从干净 Plan E 基线建立最小 `ezagent_plugin_git_workflow` owner app：经统一
authority chokepoint 授权的 claim 只创建/返回 durable、non-secret、
`status: :accepted` workflow intent；并发相同 claim 返回同一 run，状态转换使用
真实 PostgreSQL 单语句 compare-and-swap。不得把旧 A/A2 的 claim-time 全量
authority materialization 带回来。

## 1. 工作区坐标

本 handoff 是 coordinator 交付文件，不在 worker base commit 内。worker 创建
worktree 前先从以下绝对路径完整读取：

```text
/home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-integration/docs/superpowers/handoffs/2026-07-24-plan-e-e2-workflow-intent-handoff.md
```

必须使用：

```text
repo: /home/huangjiajia/ezagent
worktree: /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-workflow-intent
branch: feat/git-provider-v1-plan-e-workflow-intent
base: e34b45c5a6d572180af0899d24b7ce05e4267c9e
test partition: plan_e_e2
```

若该 branch 或 worktree 已存在，停止并回报，不得复用旧 A/A2 worktree。创建命令：

```bash
git -C /home/huangjiajia/ezagent worktree add \
  /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-workflow-intent \
  -b feat/git-provider-v1-plan-e-workflow-intent \
  e34b45c5a6d572180af0899d24b7ce05e4267c9e
```

开始后第一条 return 必须包含：

```bash
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short
```

不得切换或修改 `/home/huangjiajia/ezagent` 主 worktree。

## 2. Required reading

写代码前完整加载：

1. repo `AGENTS.md`；
2. skills：`brainstorming`、`executing-plans`、`test-driven-development`、
   `ezagent-developer`、`project-discussion-ezagent`、`elixir-phoenix-helper`、
   `dev-together`、`verification-before-completion`、`commit-work`；
3. `docs/superpowers/specs/2026-07-24-git-provider-v1-plan-e-simplified-execution-amendment.md`；
4. `docs/superpowers/plans/2026-07-24-git-provider-v1-plan-e-simplified-implementation.md`
   的 §0、§5、§14；
5. `apps/ezagent_core/lib/ezagent/cap/authorize.ex`；
6. `apps/ezagent_core/lib/ezagent/cap/verifier.ex`；
7. 当前 Git domain：
   `apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex` 和
   `apps/ezagent_domain_git/lib/ezagent/domain_git/repository_ref.ex`。

## 3. 当前实证

- 当前 unified authorization 保留稳定 denial：
  `apps/ezagent_core/lib/ezagent/cap/authorize.ex:35-62`；
- `authenticated_principal` fail-closed：
  `apps/ezagent_core/lib/ezagent/cap/authority.ex:104-106` 和
  `apps/ezagent_core/lib/ezagent/cap/verifier.ex:48-120`；
- `GitTaskAccess` 已冻结 exact authority coordinates：
  `apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex:30-69`；
- runnable sibling app 必须进入 release：
  `mix.exs:25-58`；
- web app 通过 umbrella dependency 启动 sibling plugins：
  `apps/ezagent_web/mix.exs:90-135`；
- migration source of truth 位于
  `apps/ezagent_core/priv/repo/migrations/`。

旧 A/A2 branch 中的 app scaffold 只能用来理解曾经的失败方向；禁止复制
`PolicySet.materialize/3`、claim-time issue/store/verify 或所谓跨
PostgreSQL/Kind/Cap 原子提交。

## 4. Locked decisions

| # | 决策 | 冻结值 |
|---|---|---|
| 1 | claim success | 只表示 `status: :accepted` |
| 2 | principal | reviewed ingress 必须显式携带 `authenticated_principal` |
| 3 | authorization | 使用当前 unified CapBAC chokepoint；denial 语义保持 #1503 |
| 4 | claim side effects | 只允许 binding read + run insert/load；无 lifecycle/provider side effect |
| 5 | idempotency | PostgreSQL unique constraint + insert/fresh-read |
| 6 | transition | 单 SQL `WHERE id AND state_version` CAS |
| 7 | persisted data | non-secret provider-neutral coordinates/intent；无 token/raw provider map |
| 8 | app dependency | workflow 不依赖 GitHub/Kanban/socialware plugin |
| 9 | later stages | workspace/worker/authority/sidecar/provider 全部延期到 E3/E4 |
| 10 | old A/A2 | 不 merge/cherry-pick；按本 handoff 重新 TDD |

## 5. 允许改动

新 app：

- `apps/ezagent_plugin_git_workflow/mix.exs`
- `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/application.ex`
- `.../task_binding.ex`
- `.../workflow_run.ex`
- `.../store.ex`
- `.../task_intake.ex`
- `apps/ezagent_plugin_git_workflow/lib/ezagent/behavior/git_workflow.ex`
- 对应 `test/**`

必需 wiring：

- 新建
  `apps/ezagent_core/priv/repo/migrations/20260724010000_create_git_workflow_intents.exs`
- `mix.exs` release application list
- `apps/ezagent_web/mix.exs` umbrella dependency
- 只有 architecture gate 证明需要时，更新其既有 manifest/path list

不得修改：

- GitHub plugin；
- Kanban、socialware、skills_seed；
- Git domain entity/action vocabulary；
- workspace/agent/sidecar production modules；
- core CapBAC 语义或 allowlist/豁免。

## 6. 数据与 action contract

### 6.1 Binding

`git_workflow_bindings` 保存：

```text
id
generation
workspace_uri
task_receiver_uri
credential_owner_uri
repository_uri/provider_adapter/provider_host/external_id/owner_path/base_ref/visibility
allowed_head_namespace
enabled
inserted_at/updated_at
```

所有 URI 使用现有 canonical URI/Ecto type；repository 经 `RepositoryRef.new/1`
验证。禁止 credential/token/private key/installation id/OAuth value 字段。

### 6.2 Run

`git_workflow_runs` 保存：

```text
id
binding_id + binding_generation
external_task_id
authenticated_principal_uri
status = "accepted"
state_version = 1
input_digest
source_task_uri
source_revision
requested_head_ref
last_error_code
inserted_at/updated_at
```

唯一键：

```text
(binding_id, binding_generation, external_task_id)
```

`input_digest` 不进入唯一键；命中已有行后比较 digest。同
binding/generation/task、相同 digest 是 exact retry；不同 digest 必须返回 closed
conflict，不创建第二条 run。intent 使用显式 typed columns/validated struct，禁止
任意 JSON/map payload、provider response 或 credential metadata。

### 6.3 Actions

最小 `Ezagent.ActionSet.GitWorkflow` 只声明：

```text
register_binding
disable_binding
claim_task
read_run
```

binding 管理走 sanctioned workspace admin authority；`claim_task` 必须从 dispatch
ctx 提取 `authenticated_principal`，不能接受 args 中伪造 principal。不要声明
materialize/spawn/provision/create_pr/wait_ci/merge/project actions。

### 6.4 CAS

`Store.transition(run_id, expected_version, expected_status, next_status)` 必须执行单条
条件 update。更新数为 0 时 fresh-read 并区分：

- exact retry：已是同一 next state/version，返回当前 run；
- stale version：`:stale_state_version`；
- status conflict：`:workflow_state_conflict`；
- terminal conflict：`:workflow_terminal`。

不得用 `Repo.get → changeset update`、GenServer、Agent、ETS 或 application lock
承担并发正确性。

## 7. 实施顺序

1. 创建 worker-local `plan.md/in-progress.md/done.md`，保持更新。
2. 先写 migration/schema/authority/concurrency tests。
3. 运行 red：

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 \
  mix test apps/ezagent_plugin_git_workflow/test/
```

4. 实现最小 app/plugin declaration 与 schemas。
5. 实现 governed binding validation/registration。
6. 实现 claim authorization、insert-or-load 和 conflict semantics。
7. 实现 transition CAS。
8. 加 architecture tests，至少静态拒绝 claim call graph 中出现：
   `Kind.spawn`、`Cap.issue`、workspace provision、Agent/sidecar、adapter/Req、
   GitHub/Kanban module。
9. 完成 release/web wiring，运行 declarative plugin test。
10. 运行 focused tests：

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 \
  mix test apps/ezagent_plugin_git_workflow/test/

MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 \
  mix test apps/ezagent_core/test/architecture/ \
           apps/ezagent_core/test/invariants/all_plugin_apps_wired_to_web_test.exs
```

11. 运行完成门：

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 mix ci.fast
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 mix precommit
git diff --check
```

12. review/stage 仅 E2 文件，提交逻辑清晰的 commit；migration 只保留一个最终版本，
不得追加 correction migration 掩盖同分支错误。

## 8. Definition of Done

- [ ] missing `authenticated_principal` →
  `:authenticated_principal_required`，零 run side effect。
- [ ] revoked holder → `:holder_revoked`，零 run side effect。
- [ ] no matching cap → `:no_matching_cap`，零 run side effect。
- [ ] authorized claim 只产生一条 `accepted` run，无
  Kind/cap/workspace/Agent/sidecar/provider side effect。
- [ ] 20 个 concurrent identical claims 返回同一 run id，DB 只有一行。
- [ ] 同 task 不同 input digest closed conflict。
- [ ] 20 个 concurrent same-version transitions 只有一个成功。
- [ ] exact retry 幂等；stale/status/terminal conflict 稳定。
- [ ] binding/run schemas 无 secret/provider-private/lifecycle-result 字段。
- [ ] workflow app 无 GitHub/Kanban/socialware plugin dependency。
- [ ] release wiring 与 `:ezagent_plugin_check` 通过。
- [ ] focused tests、`mix ci.fast`、`mix precommit` 通过。
- [ ] branch 基于指定 SHA，worktree clean，return 包含 commit SHA 和全部证据。

任一行只能由 lead defer，worker 不得删除或自行宣布 defer。

## 9. Discuss-first / deferred

**Discuss-first：**

- 当前 sanctioned admin/claim authorization 无法在不改 core CapBAC 的情况下表达；
- workflow binding 必须新增跨 plugin dependency；
- PostgreSQL 唯一约束无法表达“同 task 不同 digest closed conflict”；
- release wiring触发已存在但与本 branch 无关的 invariant failure。

遇到这些情况停止扩大实现，回报最小 reproducer、file:line 和两个可选 seam；不得
擅自加 CapBAC exemption/allowlist。

**Deferred 到 E3：** workspace、worker principal、policy obligation、
issue/store/strict verify、runner/reconciler、sidecar ordering。

**Deferred 到 E4+：** create PR、CI/review/merge observation、Kanban、socialware、
skill、canary。

## 10. Return contract

用中文返回：

1. repo/worktree/branch/base/head SHA；
2. commit 列表；
3. `git status --short`；
4. changed files/migration；
5. DoD 逐项 `PASS/FAIL + file:line/test output`；
6. red test 与 green test 的实际命令/结果；
7. PostgreSQL concurrency test 输出；
8. `mix ci.fast`、`mix precommit` 结果；
9. dependency/CapBAC/side-effect audit；
10. 未决风险与 lead 决策项。

不得 push、开 PR、merge integration/main、操作 canary。

## 11. Paste-ready dispatch prompt

```text
执行 Plan E E2。完整读取并严格遵守：
/home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-integration/docs/superpowers/handoffs/2026-07-24-plan-e-e2-workflow-intent-handoff.md

所有沟通与 return 使用中文。必须从文档写死的 base SHA 创建指定独立 linked
worktree/branch；不得修改受管控 main worktree；不得复用或 cherry-pick A/A2；
不得越过 E2 owner surface；claim 只能落 accepted intent，严禁 workspace/worker/
policy/cap/sidecar/provider 实现；不得读取 secret、push、开 PR 或操作 canary。

先回报 repo、绝对 worktree、branch、base SHA、git status；按 TDD 实施并完成全部
DoD/gates；最后按 §10 return。
```
