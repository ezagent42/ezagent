# Handoff: watcher-merge — review + merge PR #963（`watcher-fix` → main）

> **Date:** 2026-06-25 · **From:** allen(lead) · **To:** an independent developer (human + cc/codex)
> **Tracking:** PR #963 / task `watcher-merge` · **Base:** `origin/main` @ `e3b6ffba`（watcher-fix tip 已含其上）
> **Status:** confirmed — review+merge 阶段。单提交、dev-only、CI 全绿（precommit ✓）。这是最小、最快清空的合并。

## 0. Mission
PR #963 是 `config/dev.exs` **一处**改动：dev watcher 从 `npm run dev`（派生 npm→sh→node(vite) 三层进程树）改成 **node 直跑 vite**（单进程），根治 5173 孤儿端口占用（`:watcher_command_error`）。根因：`npm` 不可靠转发 SIGTERM 给子进程，BEAM 关闭时只 SIGTERM 到 npm，孙子 vite 漏杀、reparent 成孤儿、继续占 5173。dev-only、**零产品代码**、单提交。**你的活：确认 diff 只动 `config/dev.exs`、确认无产品风险、lead 合 `watcher-fix`→main。**

## 1. Required reading（review 前）
1. Skill **dev-together** — 本工作流 + handoff standard。
2. 本 PR 的 return：`docs/together/2026-06-24/returns/watcher-fix.md`。
3. （Skill **ezagent-developer** 列在 standard 里；本 PR 不碰 invariants 面，过一眼即可。）

## 2. Locked decisions（已定，勿翻案）
| # | Decision | Value |
|---|----------|-------|
| 1 | watcher 进程模型 | node 直跑 `node_modules/.bin/vite`（单进程，BEAM 经 erl_child_setup 直管），不再经 `npm run dev` 三层树 |
| 2 | 端口 | `WORLD_VITE_PORT` || `5173`，`--host 0.0.0.0`；`cd:` 指 `apps/ezagent_plugin_world/assets` |
| 3 | 范围 | dev-only（`config/dev.exs`），零产品代码，不影响任何 gate |
| 4 | `.tool-versions` pin | **已 drop**（main CI 已 1.19/OTP28；之前误判"arch 套件只 OTP27 过"实为 async test-harness flaky，工具链无关） |

## 3. Architecture primer
- 只动 `config/dev.exs` 的 `watchers:` 列表：`npm: [...]` → `node: ["node_modules/.bin/vite", "--host", "0.0.0.0", "--port", PORT, cd: assets_path]`。
- `esbuild` / `tailwind` watcher 不变。
- 这是 Phoenix.Endpoint Watcher 信号转发问题，不是 Ezagent router 语义——**不触任何 Kind/Behavior/dispatch/CapBAC 面**。

## 4. Design（+ review status）& phased plan
**成品 PR，无需 build。**
- **Phase R1 — 确认 diff**：`git show 58b27374 -- config/dev.exs`，确认 8 insertion / 7 deletion，**只此一文件**。
- **Phase R2 — 确认无产品风险**：dev-only config，不进 prod；`mix precommit` 已绿。
- **Phase R3 — lead merge**：合 `watcher-fix`→main。

## 5. Definition of Done（可展示产物）
- [ ] **运行时证据**（已验，肉眼可看）：重启后 `vite ppid = erl_child_setup`（BEAM 直管），**无 npm/sh 中间层、无 5173 孤儿**。建议 review 时复跑 `ps -ef | grep vite` 确认 ppid。
- [ ] **CI 全绿**：`mix precommit` ✓（return 已记）。dev-only 改动，gate 不受影响。
- [ ] **diff 边界**：`git show 58b27374 --stat` = `config/dev.exs | 15 ++++-------`，单文件单提交。

## 6. Discuss-first vs Deferred
**Discuss-first：** 无。**无架构决策**，无 invariant 面，机械合并。
**Deferred：** 无。
**Never deferred here：** 确认 diff 真的只动 `config/dev.exs`（防夹带）。
**人工步骤（flag）：** 运行时 ppid 证据需在一台跑得起 dev server 的机器上肉眼确认（已由作者验过；review 可复核）。

## 7. Conflict-avoidance
- **本 PR owns**：`config/dev.exs`（仅此一个文件）。
- **与 kanban-merge（#964）零冲突**：kanban **自身 commit 不碰 `config/dev.exs`**（已核对 `comm -12` 交集为空）。两 PR 互不依赖、任意顺序合。

## 8. Merge model
PR #963 改动已在任务分支 `watcher-fix`（不直接进 main）；含当前 main `e3b6ffba`；**lead 合 `watcher-fix`→main**（dev-together `close`）。lead 是唯一进 main 的路径。

## 9. Gates, file/LOC estimate, open questions
- **Gates**：`mix precommit`（含 `format` / `check_invariants` / `test`）——dev-only 改动全过。
- **规模**：1 文件，`config/dev.exs`，+8/-7。
- **Open questions（给 lead）**：
  1. ⚠️ **return 文档 SHA 与分支 tip 不一致**：`returns/2026-06-24/watcher-fix.md` 写 commit `dd2421eb`，但 **`watcher-fix` 分支 tip 是 `58b27374`**（同一 diff、同一 subject；`dd2421eb` parent `e2807c0c` 21:14 是早一版 rebase 变体，`58b27374` parent `a56ca149` 23:07 是真正 tip）。**合并以分支 tip `58b27374` 为准**——确认你拉的 PR head 指向 `58b27374`、不是悬空的 `dd2421eb`。
  2. 先合本 PR（最小、最快清空）再合 kanban，OK？（顺序非强制）
