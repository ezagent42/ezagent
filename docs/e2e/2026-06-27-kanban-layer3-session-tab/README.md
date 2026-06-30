# Layer-3 视觉验证 — session 绑板后会话内出现 kanban tab（声明式 session_tabs/0）

日期：2026-06-27 ｜ worktree：`kanban-agent-e2e` ｜ 代码 head：`eefc88ee`（Layer-3 = `eb9b6faf`）
Server：`http://world.localhost:10042`（built world bundle `/assets/world/main.js`）
板：`entity://system/agent/p2r2-115537`（PR-e2e Round2 建，绑到 `session://system/default/main`）

## Layer-3 是什么

**模块化会话 UI（声明式 `session_tabs/0`）**：一个 INSTALLED plugin 用 `session_tabs/0` 声明会话内
tab 及其 `:condition`；world 的会话视图（Conversation）把静态 `chat`/`pty` + 各 plugin 通过条件的
session tab 合并成顶部「视图切换器」。kanban 声明
`%{id: "kanban", label: "看板", condition: &BoardConfig.session_bound?/1}`
（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:130`）——**会话绑了至少一块板
才长出 kanban tab，没绑就没有**。点 tab → `session.view.switch` → `KanbanData.board_state_for_session/2`
反查绑定的板 → 会话内渲染该板（复用 world Kanban renderer，parent-owned `:subcomponent`）。

## 结论（一句话）

**Layer-3 DoD 三图全绿（E2E-PASS）**：绑了板的 session（`default/main`）会话视图切换器出现
`Chat / PTY / 看板` 三 tab（①），点「看板」渲染出绑定的板 p2r2-115537 的节点树（②）；新建一个
**没绑板**的 session（`default/l3neg`）会话视图切换器只有 `Chat / PTY`、**无看板 tab**（③）。
正面有、负面无 = 证明这 tab 是「**因为绑了板**」的声明式条件渲染，非写死。

---

## 前置（Step 0–2）

| 项 | 做法 | 证据 |
|---|---|---|
| rebuild bundle（含 Layer-3 Conversation.tsx） | `cd apps/ezagent_plugin_world/assets && pnpm run build` | `✓ built in 11.84s`，`main.js` mtime 13:02（> Layer-3 commit 12:42，旧 bundle 11:17 是 stale） |
| server 用 built bundle | dev.exs `world_module_url` 默认是 vite（5174，但 vite binary 损坏 crash-loop）→ **临时**让其读 `WORLD_MODULE_URL` env → 重起 server（`WORLD_MODULE_URL=/assets/world/main.js`）；**事后 `git checkout config/dev.exs` 已还原** | curl `/sessions` 含 `data-world-module-url="/assets/world/main.js"`；`git status` 无 tracked 改动 |
| 健康 | rebase 带的迁移 `20260628000000` 跑掉；server root 302 / app.js 200 / world main.js 200 | — |
| 后端 session_tabs live | 只读 RPC：`plugin_session_tabs("session://system/default/main")` = `[%{"id"=>"kanban","label"=>"看板"}]`；`BoardConfig.session_bound?("session://system/default/main")` = `true` | — |

---

## 逐步证据 + #1024 分级

| # | 步骤 | 分级 | 证据 |
|---|---|---|---|
| ① | 正面：绑板 session 切换器出现 kanban tab | **E2E-PASS** | `01-bound-session-switcher-has-kanban-tab.png`。进 `/sessions?session=session://system/default/main` 会话视图，切换器 CDP eval `switcher_text="Chat\|PTY\|看板"`、`has_kanban_tab=true`（`[data-session-tab="kanban"]` 存在） |
| ② | 正面：点 kanban tab 渲染绑定的板 | **E2E-PASS** | `02-kanban-tab-renders-bound-board.png`。CDP 真点击「看板」tab → `session.view.switch` dispatch → 会话内渲染 `看板 · p2r2-115537`（GitHub: jjkysy/test-ezagent），CDP eval `nodes=2`、`board_title="p2r2-115537"`、`__nodeIds()=["n1","n2"]` |
| ③ | 负面对照：没绑板 session 无 kanban tab | **E2E-PASS** | `03-unbound-session-no-kanban-tab.png`。经 UI「New session」真建 `session://system/default/l3neg`（未绑任何板）→ 会话视图切换器 CDP eval `switcher_text="Chat\|PTY"`、`has_kanban_tab=false`。**正面有/负面无 = 条件渲染成立** |

**对照矩阵**

| session | 绑板？ | 切换器 | kanban tab |
|---|---|---|---|
| `session://system/default/main` | ✅ p2r2-115537 | Chat \| PTY \| **看板** | 有（点开渲染该板） |
| `session://system/default/l3neg` | ❌ | Chat \| PTY | **无** |

---

## sanctioned 路径 / 铁律自查

- 操作全走 sanctioned UI（CDP 真点击/填表 → LiveView `world:dispatch`/`session.*` → authz）：
  会话切换 tab 走 `session.view.switch`；建会话走「New session」表单 → `session.create`。
- **未用 raw RPC 驱动任何操作**；只读 RPC 仅 forensics（`plugin_session_tabs`/`session_bound?`/
  `list_sessions`/`get_tree`(read)）。
- **token 不外露**：本任务无 github 写动作；所有命令输出仍按惯例 redact。
- **未碰用户 10052/5176**；只用 10042 + chrome 9222。
- **config/dev.exs 改动已 `git checkout` 还原**（临时让 `world_module_url` 读 `WORLD_MODULE_URL` env，
  仅为让 dev server 用 built bundle 绕开损坏的 vite watcher）；`git status` 无 tracked 文件改动。

## 卡点 / 备注

- dev server LiveView WS 连接慢/抖（最长 ~60–130s 才 `isConnected`，vite watcher crash-loop 噪声 +
  冷节点），已用 poll-until-connected 规避；非阻断。
- server 因 rebase（committed eefc88ee + 迁移 `20260628000000`）一度 503，跑迁移 + 干净重起后稳定。

## 截图清单

| 文件 | 内容 | 分级 |
|---|---|---|
| `01-bound-session-switcher-has-kanban-tab.png` | 绑板 session：切换器 Chat/PTY/**看板** | E2E-PASS |
| `02-kanban-tab-renders-bound-board.png` | 点看板 tab → 渲染绑定板 p2r2-115537（n1/n2） | E2E-PASS |
| `03-unbound-session-no-kanban-tab.png` | 没绑板 session l3neg：切换器仅 Chat/PTY | E2E-PASS |
