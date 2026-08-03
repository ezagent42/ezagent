# Handoff：Plan E E1 — GitHub App operation-scoped credential

> **日期：** 2026-07-24 · **From：** Plan E lead · **To：** 独立 implementation worker
> **Tracking：** Git Provider V1 Plan E / E1 · **Base：**
> `integration/git-provider-v1-plan-e` @
> `e34b45c5a6d572180af0899d24b7ce05e4267c9e`
> **状态：** confirmed — 设计已获 lead 确认，可实施 E1；禁止扩大到 E0/E2–E9

## 0. Mission

把 GitHub repository operation 的 installation credential 改为
operation-scoped mint：每个 `DomainGit.Adapter` callback 为 exact repository 和
closed permission profile mint 一次，callback 内有限 HTTP 批次可复用，返回前丢弃；
完全删除当前 account-wide ETS cache/Agent，但不改变 provider-neutral Git domain。

## 1. 工作区坐标

本 handoff 是 coordinator 交付文件，不在 worker base commit 内。worker 创建
worktree 前先从以下绝对路径完整读取：

```text
/home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-integration/docs/superpowers/handoffs/2026-07-24-plan-e-e1-operation-credential-handoff.md
```

必须使用：

```text
repo: /home/huangjiajia/ezagent
worktree: /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-app-operation-credential
branch: feat/git-provider-v1-plan-e-app-operation-credential
base: e34b45c5a6d572180af0899d24b7ce05e4267c9e
test partition: plan_e_e1
```

若该 branch 或 worktree 已存在，停止并回报，不得复用旧 H/H2 worktree。创建命令：

```bash
git -C /home/huangjiajia/ezagent worktree add \
  /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-app-operation-credential \
  -b feat/git-provider-v1-plan-e-app-operation-credential \
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
   的 §0、§4、§14；
5. GitHub 官方
   [`Create an installation access token for an app`](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app)。

## 3. 当前实证

- account-wide cache 与 Agent owner：
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex:17-23`、
  `:28-60`；
- cache public test seam：
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex:77-100`；
- 当前 mint body 是 `%{}`：
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex:104-118`；
- adapter 已按 callback 先取 installation token：
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex:32-50`、
  `:363-370`；
- GitHubInstallation 仍是 supervised child：
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex:53-75`。

## 4. Locked decisions

| # | 决策 | 冻结值 |
|---|---|---|
| 1 | repository auth | 只使用 GitHub App installation token；OAuth user token 不 fallback |
| 2 | token lifetime | 一个 adapter callback/observation callback；不得跨 callback |
| 3 | token storage | 无 ETS、Agent/GenServer state、process dictionary、persistent term、DB/event/log |
| 4 | permission selector | `GitHubAdapter` 静态选择；caller/Agent/action args 不得选择 |
| 5 | repository scope | mint request 只含 exact repository name |
| 6 | response validation | `repository_selection/repositories/permissions/expires_at` 严格核对后才发 repo request |
| 7 | domain | 不修改 `ezagent_domain_git` interface/entity/action vocabulary |
| 8 | trust boundary | token 可短暂存在于 reviewed GitHub plugin callback stack，不得离开 plugin |
| 9 | merge | 不增加 merge/submit-review action |
| 10 | old H/H2 | 可阅读 review finding，禁止 cherry-pick/复制 reservation state machine |

## 5. 允许改动

主要 owner surface：

- `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex`
- `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_installation.ex`
- `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex`
- 新建
  `apps/ezagent_plugin_github/lib/ezagent_plugin_github/installation_permissions.ex`
- GitHub plugin 对应 tests
- 新建 GitHub plugin architecture invariant test

不得修改：

- `apps/ezagent_domain_git/**`
- `apps/ezagent_domain_provider_connection/**`
- `apps/ezagent_plugin_kanban/**`
- workflow/socialware/skills_seed
- `mix.exs` release topology与 `apps/ezagent_web/**`

若测试证明必须跨出 owner surface，停止并只提交 file:line finding；不得擅自改。

## 6. 目标 contract

plugin-internal seam：

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

`GitHubAdapter` 静态映射：

```text
resolve_repository       → metadata read
create_change_request    → metadata read + contents write + pull_requests write
read_change_request      → metadata read + pull_requests read
list_checks              → metadata read + checks read
list_reviews             → metadata read + pull_requests read
```

请求：

```elixir
%{
  repositories: [repo_name],
  permissions: InstallationPermissions.for!(:change_request_write)
}
```

返回 scope 必须恰好覆盖请求的 repository/profile，不接受 all-repositories、
额外 repository 或更宽 write permission。error atom 使用
`:installation_scope_mismatch`；既有 GitHubClient 401/403/404 映射保持稳定。

## 7. 实施顺序

1. 创建 worker-local `plan.md/in-progress.md/done.md`，保持更新。
2. 先改 tests，运行并保存 red：

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e1 \
  mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_installation_test.exs
```

3. 测试必须覆盖 exact request、strict response、callback mint count、no cache、
secret sentinel。
4. 删除 GitHubInstallation 的 Agent child 与所有 ETS/cache seam。
5. 实现 closed permission map 与 operation-scoped mint。
6. 修改 adapter，使每个 callback 只 mint 一次；create PR callback 内多次 Req 使用
   同一本地 token。
7. 增加结构 gate，禁止 cache/state/action exposure。
8. 运行 focused suite：

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e1 \
  mix test apps/ezagent_plugin_github/test/
```

9. 运行完成门：

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e1 mix ci.fast
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e1 mix precommit
git diff --check
```

10. review/stage 仅 E1 文件，提交一组逻辑清晰的 commit。

## 8. Definition of Done

- [ ] exact repository + exact permission request；proof：Req.Test request body。
- [ ] malformed/missing/wider response 在首个 repo HTTP 前 fail closed。
- [ ] 两个 adapter callbacks mint 两次；一个 create callback 的多 HTTP 批次 mint
  一次。
- [ ] GitHubInstallation 无 ETS/Agent/GenServer/process dictionary/persistent term。
- [ ] `put_cached_token/3` 和其他 public cache/token seeding seam 不存在。
- [ ] token sentinel 不进入 action result、mapped error、Logger、Application env、
  event/DB/state。
- [ ] OAuth credential 没有成为 installation credential fallback。
- [ ] Git domain/provider contract 无变化。
- [ ] `:ezagent_plugin_check`、focused tests、`mix ci.fast`、`mix precommit` 通过。
- [ ] branch 基于指定 SHA，worktree clean，return 包含 commit SHA 和全部证据。

任一行只能由 lead defer，worker 不得删除或自行宣布 defer。

## 9. Discuss-first / deferred

**Discuss-first：**

- 官方 response 在 Req.Test/当前 API 版本上与上述字段不一致；
- exact profile 需要 GitHub App 当前未授予的权限；
- 必须改 Git domain 或 provider-connection；
- 发现 token 需要跨 callback 才能满足产品正确性。

遇到这些情况停止实现并回报证据。

**Deferred 到 E9：** 真实 GitHub App installation/canary、真实 rate-limit/latency
证据。E1 不读取 secret、不发真实 GitHub mutation。

## 10. Return contract

用中文返回：

1. repo/worktree/branch/base/head SHA；
2. commit 列表；
3. `git status --short`；
4. changed files；
5. DoD 逐项 `PASS/FAIL + file:line/test output`；
6. red test 与 green test 的实际命令/结果；
7. `mix ci.fast`、`mix precommit` 结果；
8. token exposure/cross-owner audit；
9. 未决风险与 lead 决策项。

不得 push、开 PR、merge integration/main、操作 canary。

## 11. Paste-ready dispatch prompt

```text
执行 Plan E E1。完整读取并严格遵守：
/home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-integration/docs/superpowers/handoffs/2026-07-24-plan-e-e1-operation-credential-handoff.md

所有沟通与 return 使用中文。必须从文档写死的 base SHA 创建指定独立 linked
worktree/branch；不得修改受管控 main worktree；不得复用或 cherry-pick H/H2；
不得越过 E1 owner surface；不得读取 secret、push、开 PR 或操作 canary。

先回报 repo、绝对 worktree、branch、base SHA、git status；按 TDD 实施并完成全部
DoD/gates；最后按 §10 return。
```
