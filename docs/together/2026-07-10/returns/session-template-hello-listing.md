# Return — hello 模板创建的 session 未出现在列表/Overview

> **Task:** session-template hello listing consistency（用户临时缺陷修复）
> **Branch:** `codex/fix-session-class-listing`
> **PR:** https://github.com/ezagent42/ezagent/pull/1320
> **Dev:** Codex（zyli-developer 席位）
> **returned_at:** 2026-07-10 17:53 +0800
> **deadline:** 2026-07-10 20:00 +0800
> **deadline_status:** out_of_scope

## What changed

- 修复 class-template/session.* 路径创建 session 时没有把 creator join 成 session member 的问题；现在该路径和标准 facade 创建路径一致，会把创建者加入成员列表。
- 给 session facade 增加窄口径 `join_session_members/2`，供 workspace class-template path 调用，避免 workspace 层绕过 session materializer。
- Overview 的 `Sessions` KPI 和“可继续的 Sessions”改为复用会话页同一套 `ConversationSessionState.rows_for_workspace(workspace_uri, caller_uri)`，确保总数和列表同一 workspace/caller 可见性口径。
- 增加回归测试：非 admin creator 通过 class-template 创建 session 后，filtered `list_sessions(workspace, creator)` 可以看到该 session。

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | 找出 hello template session 计入 Overview 总数但不出现在 session list / 可继续列表的原因 | met | 根因拆成两段：class-template 创建路径没有 join creator；Overview KPI/list 使用不同 session 数据口径。 |
| 2 | 修复 hello 模板创建的 session 在 session list 中不可见的问题 | met | `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex` joins creator via session facade；`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex` 暴露窄 join helper。 |
| 3 | 修复 Overview 中 Sessions KPI 与“可继续的 Sessions”列表不一致 | met | `apps/ezagent_plugin_world/lib/ezagent/world/admin_data.ex` 复用 `ConversationSessionState.rows_for_workspace/2`；浏览器验证 Overview 显示 `Sessions = 3` 且包含 `/hello/test-hello-1116`。 |
| 4 | 增加自动化回归保护 | met | `POSTGRES_PORT=5432 mix test apps/ezagent_domain_session/test/integration/generic_session_create_via_workspace_test.exs` → 2 tests, 0 failures。 |
| 5 | 使用本机 PostgreSQL 5432 完成验证 | met | 本地验证命令均显式 `POSTGRES_PORT=5432`；之前误用 55432 的原因是 repo 默认配置，不再沿用。 |
| 6 | dev-together machine return gate (`precommit + check_invariants` / `mix ci.local`) | not-met | `PATH=/tmp/codex-pnpm-bin:$PATH POSTGRES_PORT=5432 mix ci.local` 失败在 assets install：npm registry TLS/ECONNRESET，`pnpm install failed in apps/ezagent_web/assets`；未进入完整 gate。Lead 决定是否在 CI 环境重跑或补网络后重跑。 |

**Method friction:** 本次没有正式 handoff，DoD 是从用户线上症状即时反推；这类临时缺陷修复在 return 时容易撞上“machine gate 必须绿”和“本地网络/registry 不稳定”的冲突。建议 lead 对 out-of-scope hotfix return 允许记录 `gate_blocked_by_env`，但保持不可合并判定直到 GitHub CI 绿。

## Validation evidence

- Compile: `POSTGRES_PORT=5432 mix compile --warnings-as-errors` ✅
- Targeted regression: `POSTGRES_PORT=5432 mix test apps/ezagent_domain_session/test/integration/generic_session_create_via_workspace_test.exs` ✅
- Browser verification on `http://world.localhost:10042` ✅
  - Overview screenshot: `C:/Users/Lenovo/.codex/visualizations/2026/07/10/019f4ae0-0a58-72d1-99e7-75a735304889/overview-visible-1320-v2.png`
  - Sessions screenshot: `C:/Users/Lenovo/.codex/visualizations/2026/07/10/019f4ae0-0a58-72d1-99e7-75a735304889/sessions-visible-1320-v2.png`
- Strict local gate: `mix ci.local` ❌
  - Log: `/tmp/ezagent-ci-local-1320-return.log`
  - Failure: `ERR_PNPM_META_FETCH_FAIL` / `ECONNRESET` against `registry.npmjs.org`, then `pnpm install failed in apps/ezagent_web/assets`.

## Rebase / branch state

- Rebased onto current `origin/main`: `e8858b3b2f5477eec9fa916fbda745fc1e29126b`
- Code head before this return-doc commit: `cbd51a663ec1ee245884d3fef06789fc64f623df`
- PR: https://github.com/ezagent42/ezagent/pull/1320

## Merge request

Return the PR to lead as **functionally verified but strict-gate blocked locally**. Do not merge solely from this return; require GitHub CI green on the pushed head or a successful rerun of `mix ci.local` after npm registry access is stable.