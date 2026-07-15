# 前端 CI 覆盖续 · return

> **Task:** zyli — 前端 CI 覆盖续（`tsc --noEmit`，用户追加 Vitest、ESLint）
> **Branch:** `ci/frontend-tsc-noemit`
> **PR:** https://github.com/ezagent42/ezagent/pull/1415
> **Dev:** zyli-developer + Codex
> **returned_at:** 2026-07-15 17:12 +0800
> **deadline:** 2026-07-15 23:59 +0800
> **deadline_status:** on_time

## contributing_read_through

- `docs/together/contributing/README.md`
- `docs/together/contributing/socialware-data-deployment-boundary.md`
- `.claude/skills/dev-together/SKILL.md`
- `.claude/skills/dev-together/commands/return.md`
- `.claude/skills/dev-together/references/handoff-standard.md`
- `ezagent-developer` skill（含 frontend/UI contract）

## 完成内容

1. 三个前端 assets 都有可执行的 `typecheck`，并在 required CI gate 中通过
   frozen pnpm lockfile 安装后真实运行 `tsc --noEmit`。
2. 三个前端 assets 都增加 Vitest 单元测试：
   - Web：mention autocomplete 4 tests；
   - World：session/socialware helpers 4 tests；
   - Hello：36-component catalog contract 2 tests；
   - 合计 3 files / 10 tests。
3. 三个前端 assets 都增加 ESLint 10 flat config 和 `lint` script：
   - Web：JavaScript recommended；
   - World / Hello：JavaScript + TypeScript recommended、React Hooks 调用顺序；
   - 所有 lint 使用 `--max-warnings 0`。
4. CI 的 frontend step 现在固定执行：
   `pnpm install --frozen-lockfile` → `lint` → `typecheck` → `test`。
5. 修复既有 TypeScript/ESLint 确定性问题，并补齐浏览器/Vite 声明；未改
   World 运行时 UI 行为。

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | 三个 assets 的 `tsc --noEmit` 在 CI 中真实运行。 | met | `.github/workflows/ci.yml` 的 `Frontend lint, typecheck and unit tests` step；Web/World/Hello 本地 rebase 后各自 `typecheck` EXIT=0。 |
| 2 | 构造类型错误证明 gate 会失败，再修复恢复绿色。 | met | 开发过程中注入负向类型错误，`tsc --noEmit` 非零退出；回滚 probe 后三项目 typecheck 恢复 EXIT=0。该 probe 不作为生产源码提交。 |
| 3 | CI 绿，且分支 rebase 到 current `main`。 | met | frontend-only cleanup head `36f1f55e5` 的 CI **success**：https://github.com/ezagent42/ezagent/actions/runs/29406286521 ；最新 rebase base = `origin/main` `3407c7de6571562a438b71c30b65c159c52103ee`。 |
| 4 | 用户追加：补充前端单元测试并纳入 CI。 | met | Vitest 3 files / 10 tests 全绿；测试文件：`mention_autocomplete.test.js`、`SessionsTable.test.ts`、`catalog.test.ts`。 |
| 5 | 用户追加：补充 ESLint 并纳入 CI。 | met | 三套 `pnpm lint` 均 EXIT=0、零 warning；三份 `eslint.config.mjs` + frozen lockfile 已提交。 |
| 6 | 用户纠正范围：本 PR 只保留前端 CI，不包含 Elixir/OTP 全仓统一。 | met | 最终 diff 不再包含根/child/fixture `mix.exs`、kanban operator scripts 或 `toolchain_version_test.exs`；`apps/ezagent_cli/mix.exs` 已恢复到共同基点。 |

**Method friction:** 今日 plan/handoff 把 ESLint/Vitest 列为后续分期，但任务执行中
由用户明确追加到同一 PR；后续此类增量应在追加时同步扩写 handoff DoD，避免 return
阶段才补闭集。Elixir/OTP 全仓统一也曾随版本核对进入本分支，但会扩大到 CLI、后端、
插件和 fixture 的兼容性边界；用户确认本 PR 只做前端 CI 后已整体移除。另一次 rebase
后 `_build` 中旧 scanner BEAM 让 `arch.scan` 假报
`concatenated_namespace_modules: 1`；AST 对账确认源码候选全部已 sanctioned，执行
`mix compile --force --warnings-as-errors` 后计数恢复 0。建议 rebase 后静态 scan 前先
确保 scanner 已按新 main 重编译。

## Gate / proof

### Rebase

- `rebase_base_sha`: `3407c7de6571562a438b71c30b65c159c52103ee`
- code head before return document: `99393304d3e8d6e1a78748c79d552cd70afbd447`
- `git merge-base HEAD origin/main` 与 `git rev-parse origin/main` 一致。

### 完整静态 gate（rebase 后，本地）

| Gate | Result |
|------|--------|
| `mix compile --force --warnings-as-errors` | PASS |
| `mix ezagent.arch.scan` | PASS（所有 counter；`concatenated_namespace_modules 0/0`） |
| `mix ezagent.doc.scan` | PASS（0/0 modules；404/404 defs；0/0 dynamic heads） |
| `mix ezagent.uri_query.scan` | PASS（hard-fail，0 violations） |
| `mix ezagent.check_invariants` | PASS（all in-scope invariants clean） |
| Web / World / Hello `pnpm lint` | PASS，0 warnings |
| Web / World / Hello `pnpm typecheck` | PASS |
| Web / World / Hello `pnpm test` | PASS，10/10 tests |
| `git diff --check` | PASS |

### PR-head CI

- Pre-rebase functional head `3351075ef`: **success** —
  https://github.com/ezagent42/ezagent/actions/runs/29402133418
- Return document head `18db5ddc5`: **success** —
  https://github.com/ezagent42/ezagent/actions/runs/29403798001
- Frontend-only cleanup head `36f1f55e5`: **success** —
  https://github.com/ezagent42/ezagent/actions/runs/29406286521

### 已知本地环境限制

`mix precommit` 已进入全量测试；仅两个既有 `HomeMigrationTest` 因本机没有
`pg_dump` 返回 `{:missing_executable, "pg_dump"}`。这不是本分支代码失败；GitHub
gate 使用 CI PostgreSQL 环境。四道 together 静态 gate 已在
rebase 后单独完整通过。

## Deferred follow-ups / open decisions

- 原始 DoD 无延期项；本 return 不删减任何 DoD line。
- Playwright smoke 仍按今日 plan §6 留在后续分期，原始 handoff 已明确本轮范围外。
- ESLint 本轮启用 Hooks 调用顺序，不强行把既有 props/state 同步模式重构成
  `exhaustive-deps` / React compiler lint 全绿；是否另开规则收紧任务由 lead 排期。

## Merge request

请 lead 在本 return commit 的 PR-head CI 绿色后，将 Draft PR #1415 按
dev-together `push` / `close` 流程纳入今日 stack。分支已基于 current `main`，与其他
任务没有已知 merge-order 依赖；PR 涉及 `.github/workflows/ci.yml` 和三个 assets 的
配置/lockfile，若同日有其他 frontend CI 或 lockfile return，先让 lead 做冲突分析。
