# 前端 Tier-1 Playwright / 独立 CI · return

> **Task:** zyli — CI 完善 P1 / frontend Tier-1 Playwright
> **Branch:** `feat/frontend-tier1-playwright`
> **PR:** https://github.com/ezagent42/ezagent/pull/1432
> **Dev:** zyli + Codex
> **returned_at:** 2026-07-16 16:23 +0800
> **deadline:** 2026-07-16 20:00 +0800
> **deadline_status:** on_time

## contributing_read_through

- `docs/together/2026-07-16/plan.md`
- `.claude/skills/dev-together/SKILL.md`
- `.claude/skills/dev-together/commands/return.md`
- `.claude/skills/dev-together/references/handoff-standard.md`
- `ezagent-developer` skill（design principles / invariants / tier / anti-patterns）
- `2026-07-15-frontend-tier1-playwright-e2e-zyli-handoff.md`

## 完成内容

1. World island 增加纯前端静态 harness：加载构建后的 `main.js`，注入
   `layout/state/pluginNav/caller`，并 mock `pushEvent/onServerEvent`；测试阻断所有
   非 localhost 网络请求，不启动 Phoenix、LiveView socket 或数据库。
2. Playwright Tier-1 矩阵现有 13 条：Overview、sessions、conversation、PTY、admin、
   workspace plugins、kanban 渲染；四个 primary nav；`sessions.join`、
   `session.create`、`chat.send`、`kanban.save_miro_creds` payload；`world:state`
   回推重渲染；每个 fixture 都显式断言没有 `data-world-mount-error`。
3. 新增后端 `Ezagent.World.StateContract` 最小挂载契约；fixture 由
   `StateContract`、`SlotRegistry`、`PluginPageRegistry`、`DispatchContract` 投影生成。
   URI 通过 canonical `Ezagent.URI` builders 在运行时物化；无 DB 的 Mix task 仅初始化
   内建 scheme registry。checked-in JSON 由 `mix world.e2e.fixtures` 维护，`--check`
   进入 gate。
4. 新增可复用且可独立手动运行的 `.github/workflows/frontend-ci.yml`：Ubuntu 上固定
   执行三个 assets 的 ESLint、TypeScript、Vitest，以及 World Chromium Playwright；
   主 `gate (deterministic)` 显式 `needs: [frontend]`，mac full-suite 未改。
5. 新增 `FrontendCIContractTest`，锁定 workflow 调用关系、Ubuntu/Node/pnpm 版本、
   三个 assets 的 lint/typecheck/test 和 Chromium/E2E 命令。负向 probe 发现原先
   `test:e2e` 子串匹配会放过 `test:e2e-disabled`，已收紧为完整 run 行精确匹配。

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | P0：静态 harness 挂载成功、无 mount error、Overview 渲染；不启动后端。 | met | `apps/ezagent_plugin_world/assets/e2e/harness/`；`world.spec.ts` 的 `openFixture` + Overview matrix；CI frontend job 无 Elixir/Phoenix/DB step。 |
| 2 | P1：primary nav、full-bleed families、主要动作 payload 与 server reply 重渲染均有断言。 | met | `world.spec.ts` 13 tests；导航 4/4，renderer family 全覆盖，4 个 admitted dispatch 动作，`world:state` 重渲染。 |
| 3 | P2：fixture 从后端契约生成，`--check` 漂移门和 sync test 进入 gate，并演示能红。 | met | `state_contract.ex`、`e2e_fixtures.ex`、`e2e_fixtures_test.exs`、generated JSON；canonical URI builder 投影；`mix world.e2e.fixtures --check` PASS；开发期临时 mutation 被 drift gate 拒绝后恢复。 |
| 4 | P3：frontend E2E 在 Ubuntu deterministic path 运行，不占 mac full-suite。 | met | `.github/workflows/frontend-ci.yml` 使用 `ubuntu-latest`；`.github/workflows/ci.yml` 通过 reusable workflow 接线；PR CI frontend job PASS。 |
| 5 | 无新增 flaky：本地连续 20 轮全绿。 | met | `playwright test --repeat-each=20`：260/260 PASS，单 worker，2.8 分钟。 |
| 6 | 今日 plan：独立前端 workflow + 针对 CI 配置本身的回归测试。 | met | `frontend-ci.yml` + `frontend_ci_contract_test.exs`；standalone ExUnit 2/2 PASS。 |
| 7 | 今日 plan：新增回归门存在，并演示一次它能红；PR gate 绿色。 | met | 临时把精确命令改为 `test:e2e-disabled` 后 invariant 2 tests / 1 failure；反向应用同一 probe 后 2/2 PASS。最终代码 head CI run `29482921006` success。 |
| 8 | 分支基于 return 时的 current `main`，交回单一 task branch。 | met | `rebase_base_sha` 与 `origin/main` 均为 `8bc3bbefc29182b5887ee15f26230090eb77569f`；分支已 force-with-lease 推送。 |

**Method friction:** handoff 文件由协调方作为下载件提供、但今日 plan 引用的
`docs/superpowers/handoffs/...` 路径在仓库中不存在；后续应在开工前先把 handoff 落到
其引用路径，保证 return 能从仓库内逐条读取 DoD。另一个有效发现来自负向 probe：
“配置中包含字符串”不足以证明 exact CI command 存在；配置 invariant 应优先完整行或
结构化字段匹配，并必须实际跑一次 mutation-red 证明门本身承重。

完整 return 静态门还捕获了本 PR 初版 fixture 中 9 个 raw URI literal；已改为 canonical
builder 的运行时投影，并给无 DB fixture task 增加最小 registry bootstrap。最终 rebase 后，
latest `main`（#1434）自身在 `skill_reconcile.ex:142` 新增 1 条 `raw_uri_construction`
baseline；该文件相对 `origin/main` 无差异，不在本前端 PR 修复范围。当前 deterministic
workflow 未执行 `mix ezagent.uri_query.scan`，所以 CI success 不代表该 inherited baseline
已消失；应由 #1434 / 独立 follow-up 修复。

## Gate / proof

### Rebase

- `rebase_base_sha`: `8bc3bbefc29182b5887ee15f26230090eb77569f`
- code head before return document: `bd141b749fd318b75ccbe82396ac71ca72b10a5b`
- `git merge-base HEAD origin/main` 与 `git rev-parse origin/main` 一致。

### PR-head CI

最终代码 head CI：**success** —
https://github.com/ezagent42/ezagent/actions/runs/29482921006

| Check | Result |
|-------|--------|
| frontend regression gate（ESLint + TypeScript + Vitest + Chromium Playwright） | PASS |
| gate (deterministic)：Elixir 1.19 / OTP 28 compile、fixture drift、format、DB、invariants、reflow | PASS |
| gitleaks | PASS |
| dev-together return advisory / owner skill protection | PASS |
| PR-only mac full-suite / deploy dispatch | SKIPPED（workflow 设计如此，未占 self-hosted mac） |

### 本地专项证据

| Gate | Result |
|------|--------|
| World ESLint | PASS，0 warnings |
| World TypeScript（含 E2E tsconfig） | PASS |
| World Vitest | PASS，4/4 |
| Playwright functional matrix | PASS，13/13 |
| Playwright stability `--repeat-each=20` | PASS，260/260 |
| CI config standalone ExUnit | PASS，2/2 |
| CI config negative probe | EXPECTED RED，2 tests / 1 failure；恢复后 2/2 PASS |
| Elixir 1.19.2 / OTP 28.3 `compile --warnings-as-errors --force` | PASS |
| `mix world.e2e.fixtures --check` | PASS |
| `mix format --check-formatted` / GitHub YAML parse / `git diff --check` | PASS |
| `mix ezagent.arch.scan` / `mix ezagent.doc.scan` / `mix ezagent.check_invariants` | PASS（latest-main head） |
| `mix ezagent.uri_query.scan` | 本 PR World URI 已清零；latest `main` 的 `skill_reconcile.ex:142` 有 1 条 inherited baseline |

本机没有监听 `127.0.0.1:55432` 的 PostgreSQL；本地 umbrella `mix precommit` 已完成
全仓 test-env 编译，但在创建测试库时因 connection refused 退出。GitHub deterministic
gate 已提供 PostgreSQL 16 并完成 compile、fixture drift、format、DB、invariant、arch
subset 与 reflow steps，最终 run 为 success。

## Deferred follow-ups / open decisions

- 本 CI handoff 的 DoD 无延期项。
- Tier-2（真实 backend transport、SSR/hydration、真实 handler/部署 canary）按 handoff
  明确不在本 PR，继续归 mac full-suite / 后续集成任务。
- 今日 plan 的 UI P2（与 ruihua 对齐问题清单并开发）是独立协作 track，本 PR 未声称
  完成；请 lead 单独验收/排期，不与本 CI return 混算。

## Merge request

请 Allen/lead 将 Draft PR #1432 纳入今日 `push` / `close` stack。该分支已 rebase 到
return 时的 current `main`，最终代码 head required CI 全绿，无已知 merge-order 依赖；
主要冲突面是 `.github/workflows/ci.yml`，若同日还有 CI workflow return，请先做 stack
冲突分析。验收后可将 PR 标记 Ready 并合入 `main`。
