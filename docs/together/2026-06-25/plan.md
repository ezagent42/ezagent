# dev-together plan — 2026-06-25（review + merge 阶段）

> **Lead:** allenwoods（allen / 林懿伦）· **Mode:** 两个已提交 PR 的 review+merge，不是新开发
> **Base for both:** `origin/main` @ `e3b6ffba`（= 内容线 `a56ca149` / #962；`rev-list a56ca149..e3b6ffba`=0，两者同一内容线）
> **Author of both PRs:** `jjkysy`（姚升悦，human-dev，GMT+8）— team.md 标 "no active track"，本日是收尾两个昨天 late-return 的 PR
> **Status:** 两 PR 互不依赖、可任意顺序独立合（real conflict map 见下，已核对）

## 1. 今日两任务

| # | task | PR | branch | dev | DoD（可展示） | lead 动作 |
|---|------|-----|--------|-----|----------------|-----------|
| A | `kanban-merge` | #964 | `kanban-clean` | jjkysy | 浏览器 e2e 4 截图 + 全量 `mix test` 绿（**CI 已绿，含 Plan B**） | review + merge → main |
| B | `watcher-merge` | #963 | `watcher-fix` | jjkysy | 重启后 vite ppid=erl_child_setup、无孤儿；CI 全绿 | review + merge → main |

两任务都是 review+merge，不是 build。handoff 写给"接手 review/merge 的独立 dev（human + cc/codex）"。

## 2. 分支事实（已核对 git，勿凭 return 文档转述）

- **kanban-clean**：tip `5f5de0fa`，9 commit（`4b625023` feat → `580ca519` docs → `2315bf7f` 解耦 → `95a383fb` e2e+spec → `56ab78ba` CI 修1(6 失败) → `fb2b18d6` handoff 清理 → `beebdfdd` CI 修2(DocCoverage+EffectDiscipline)+docs/discuss 排除 → **`9b2ede5b` Plan B**(resource:// spawn 归属重构，解掉 #964 唯一真阻塞) → **`5f5de0fa` e2e 截图**(Plan B 后真浏览器跑通)）。**已 rebase 在当前 main `e3b6ffba`**。
- **watcher-fix**：tip `58b27374`（parent `a56ca149`），单提交，只动 `config/dev.exs`（8+/7-）。**含当前 main `e3b6ffba`**（merge-base 检查 = YES）。
  - ⚠️ **return 文档与实际 SHA 不一致**：`returns/2026-06-24/watcher-fix.md` 写 commit `dd2421eb`，但 watcher-fix 分支 tip 是 `58b27374`。两者 **同一 diff、同一 subject**，`dd2421eb`（parent `e2807c0c`，21:14）是早一版 rebase 变体，`58b27374`（parent `a56ca149`，23:07）是分支真正的 tip。**以分支 tip `58b27374` 为准。**

## 3. Conflict map —— 两 PR 互不依赖、可独立合（已核对，非转述）

按各 PR **自身 commit** 的真实改动文件集求交（不是 `git diff main..branch`——那个会被 worktree 的 `.claude/` skill 漂移污染成 1446 文件假冲突）：

| | 文件集来源 | 真实改动文件 | 关键文件 |
|---|---|---|---|
| A kanban | 5 commit `git show --name-only` | 114 个（43 在 apps/config/mix） | `apps/ezagent_plugin_kanban/**`、`apps/ezagent_plugin_world/**`、`apps/ezagent_web/lib/ezagent_web/router.ex`、`apps/ezagent_core/test/{architecture,invariants}/**` |
| B watcher | 1 commit | **1 个**：`config/dev.exs` | `config/dev.exs` |

**交集 = ∅**（`comm -12` 为空）。kanban **自身 commit 不碰 `config/dev.exs`**；watcher **只碰** `config/dev.exs`。
→ **结论：零真实冲突，任意顺序合，互不阻塞。**

> 反例澄清：直接 `git diff e3b6ffba..kanban-clean` 会列 1533 文件、`git diff e3b6ffba..watcher-fix` 列 1446 文件、二者"交集"含 `config/dev.exs` + 大量 core 文件——**全是 worktree 跨分支 `.claude/` skill 历史漂移的 artifact，不是 PR 内容**。判冲突必须按 per-commit change-set，不是 branch-vs-main diff。

## 4. 合并顺序

无依赖。建议先合 **B watcher-merge**（1 文件、dev-only、零产品风险、CI 已绿——最快清空），再合 **A kanban-merge**（#964 整个 CI 已绿、含 Plan B）。顺序非强制，可颠倒。

## 5. 决策归属（阻塞 vs 非阻塞，分清）

- **A kanban**
  - **阻塞本次合并**：CI 必须绿（8 个 architecture/invariant 失败已在 `56ab78ba`+`beebdfdd` 修 + Plan B `9b2ede5b` 解掉 spawn 真阻塞）。**#964 整个 CI 已绿**（全量 arch+invariants 串行 329/0）。lead review+merge。
  - **spawn = Plan B 已落地（不阻塞）**：原 kanban `after_boot` 注册 `resource://` scheme spawn fn（擦不变式 8 边缘）的后门**已删**，走 **Plan B**（commit `9b2ede5b`）：**workspace domain 拥 `resource` dispatcher + core `ResourceKindRegistry`（`{type→Kind}` 注册表，照 `AgentFlavorRegistry`）**，kanban 只声明 `resource_kinds/0`。CI 已绿。**剩 3 个归属决策待 Allen 确认（不阻塞合并）**：dispatcher 归 workspace 对不对 / `resource_kinds/0` 契约扩展进 Decision Log / `ConfigSurface` 搭车抽出。详见 `handoffs/spawn-ownership-planb.md` §6。
- **B watcher**：**无架构决策**。无依赖、纯 dev config、lead review+merge 即可。

## 6. Deferred（不在本日两 PR）

- **kanban agent 自动改图（Track 2，分支 `kanban-agent-mcp`，暂停中）**：通用 Kind-MCP 桥已建[暂停]，**不在 #964、不影响合并**。落地 handoff：`docs/superpowers/handoffs/2026-06-25-kanban-agent-mcp-build-handoff.md`（在 `kanban-agent-mcp` 分支）。
- **world→kanban umbrella 依赖下沉**：为过 UndeclaredDep gate，world 现声明 kanban umbrella dep；若架构上认为 world 不该依赖具体 plugin，后续更大重构（本 PR 未做）。

## 7. 产出

- `handoffs/kanban-merge.md`、`handoffs/watcher-merge.md` + 各一个 paste-ready dev prompt。
- 本 plan **不 commit**，交回 lead review。
