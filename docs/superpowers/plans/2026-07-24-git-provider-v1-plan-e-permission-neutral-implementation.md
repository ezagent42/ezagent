# Git Provider V1 Plan E Permission-Neutral Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不读取、修改或适配 Ezagent CapBAC 内部的前提下，独立收口 E1
operation-scoped GitHub App credential 与 E2-A typed durable intent/PostgreSQL
CAS，并为后续 E2-B 保留 fail-closed 薄授权边界。

**Architecture:** E1 继续由 GitHub plugin 独占 operation-scoped token。E2-A
只接受 already-validated internal command，持久化 non-secret provider-neutral
intent，并由 PostgreSQL 唯一约束和 CAS 保证并发正确性；任何 public/action
ingress 延期到 E2-B。

**Tech Stack:** Elixir/OTP、Ecto/PostgreSQL、`Ezagent.DomainGit.RepositoryRef`、
Req/Req.Test、ExUnit。

## Global Constraints

- 受管控主 worktree 固定 `main`，worker 只在各自 linked worktree 工作。
- Allen/main owns CapBAC convergence；本计划不得修改或适配 CapBAC 内部。
- E2-A 不得注册 public/action/route/CLI/agent ingress。
- 禁止 wildcard/admin fixture、`Cap.issue/store`、`EntityCaps`/`PresenterCaps`
  修改和 fake-green auth tests。
- E1 token plugin-local、operation-scoped；不得进入 workflow row、Agent、cwd、
  log、event 或 evidence。
- 当前不得读取真实 secret、执行 GitHub mutation或操作 canary。

---

### Task 1: E1 独立验收与收口

**Files:**
- Review:
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex`
- Review:
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex`
- Review/Test: `apps/ezagent_plugin_github/test/**`

**Interfaces:**
- Consumes: canonical `RepositoryRef` 与 closed permission profile。
- Produces: plugin-internal operation-scoped token callback；不产生 Ezagent
  capability。

- [ ] **Step 1: Lead 阅读 `54bfeec9a` 完整 diff 并核对 E1 handoff**
- [ ] **Step 2: Lead 重跑 focused GitHub plugin tests**
- [ ] **Step 3: Lead 重跑 secret/adversarial architecture gates**
- [ ] **Step 4: 若有 blocker，原 E1 session 做最小 correction**
- [ ] **Step 5: E1 return 只声明当前切片完成**

### Task 2: E2 dirty tree checkpoint

**Files:**
- Record: root-level gitignored `in-progress.md`
- Preserve: current E2 working tree

**Interfaces:**
- Consumes: 当前 dirty E2 tree。
- Produces: 可恢复的 checkpoint SHA；不作为 integration candidate。

- [ ] **Step 1: 记录 `git status --short` 与 `git diff --stat`**
- [ ] **Step 2: 记录最近 focused test 命令、退出码和摘要**
- [ ] **Step 3: 写 root-level `RESUME HERE`**
- [ ] **Step 4: 提交 `chore(git-workflow): checkpoint before permission-neutral pivot`**
- [ ] **Step 5: 回报 checkpoint SHA 后才开始 Task 3**

### Task 3: E2-A migration 与 typed internal command

**Files:**
- Modify:
  `apps/ezagent_core/priv/repo/migrations/20260724010000_create_git_workflow_intents.exs`
- Modify:
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/task_binding.ex`
- Modify:
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_run.ex`
- Create/Modify:
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/task_intake.ex`
- Test: `apps/ezagent_plugin_git_workflow/test/**`

**Interfaces:**
- Consumes: already-validated typed internal command。
- Produces: canonical binding 与服务端生成的 accepted intent。

- [ ] **Step 1: 写 fresh-migration、missing-field、RepositoryRef 和
  server-owned-field RED tests**
- [ ] **Step 2: 在新 test partition 运行并确认按预期失败**
- [ ] **Step 3: 修正 custom primary key、typed columns 和 canonical validation**
- [ ] **Step 4: 服务端生成 run id/digest 并强制 `accepted/1`**
- [ ] **Step 5: 运行 focused tests 至 green**

### Task 4: E2-A PostgreSQL idempotency 与 CAS

**Files:**
- Modify:
  `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex`
- Test:
  `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/concurrency_test.exs`
- Test:
  `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs`

**Interfaces:**
- Consumes: canonical accepted intent。
- Produces: insert-or-load result、digest conflict、single-SQL CAS result。

- [ ] **Step 1: 写带同步起跑点和独立 DB connection 的 concurrency RED tests**
- [ ] **Step 2: 证明现有不同 digest race 会错误返回成功**
- [ ] **Step 3: 实现 unique insert/fresh-read/digest compare**
- [ ] **Step 4: 实现并验证 one-winner CAS 与稳定 retry/conflict errors**
- [ ] **Step 5: 运行 20-way concurrency tests 至 green**

### Task 5: E2-A no-ingress 与安全 gates

**Files:**
- Remove/defer:
  `apps/ezagent_plugin_git_workflow/lib/ezagent/behavior/git_workflow.ex`
- Revert/defer: `apps/ezagent_web/mix.exs`
- Revert/defer: root `mix.exs` 中会使 E2-A 成为可调用 plugin 的 wiring
- Modify:
  `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs`

**Interfaces:**
- Consumes: E2-A internal modules。
- Produces: 不可由 public/action/route/CLI/agent caller 触达的写路径。

- [ ] **Step 1: 写 no-ingress/no-Cap/no-provider-side-effect RED gates**
- [ ] **Step 2: 删除或延期 ActionSet、web/plugin/agent registration**
- [ ] **Step 3: 删除 fake authorization tests 和 placeholder principal checks**
- [ ] **Step 4: 运行 architecture gates 至 green**
- [ ] **Step 5: 扫描 secret/provider-private/arbitrary payload 字段**

### Task 6: E2-A verification 与 Return

**Files:**
- Review: 仅 E2-A allowed files
- Exclude: app-local `plan.md`

**Interfaces:**
- Consumes: 完成的 E2-A tree。
- Produces: lead 可独立验收的 committed candidate。

- [ ] **Step 1: 运行 focused app tests**
- [ ] **Step 2: 运行 touched-app/architecture gates**
- [ ] **Step 3: 运行 `MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 mix ci.fast`**
- [ ] **Step 4: 运行适用的 `mix precommit` 和 `git diff --check`**
- [ ] **Step 5: 提交 E2-A correction 并返回 checkpoint/final SHA**
- [ ] **Step 6: Return 明确 `E2-A 当前切片完成`，不得声明 Git Provider E2E 完成**

### Task 7: Lead integration 与 E2-B resume gate

**Files:**
- Lead-only: integration branch and coordination ledger

**Interfaces:**
- Consumes: E1/E2-A candidate commits 与 `origin/main@86fd926b3`。
- Produces: permission-neutral integration baseline。

- [ ] **Step 1: Lead 分别独立 review E1 与 E2-A**
- [ ] **Step 2: 在 integration worktree 同步最新 main**
- [ ] **Step 3: 分片集成并运行交叉 gates**
- [ ] **Step 4: 记录 E1/E2-A complete，但不声明 E2E complete**
- [ ] **Step 5: 等 Allen/main 发布稳定 authorization resume contract**
- [ ] **Step 6: 从最新 main + E2-A 创建全新 E2-B worktree**
