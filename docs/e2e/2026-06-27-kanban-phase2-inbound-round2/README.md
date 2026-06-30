# Kanban Phase 2 — 入站轮询真两插件 E2E（Round2，DoD 闭环）

日期：2026-06-27 ｜ worktree：`kanban-agent-e2e` ｜ 代码 head：`f0d80805`（+ 未提交 Layer-3）
Server：`http://world.localhost:10042`（github + kanban 同节点；built world bundle `/assets/world/main.js`）
板：`entity://system/agent/p2r2-115537`（本轮经真 UI 新建）
真仓库：`jjkysy/test-ezagent`（public，default branch `ezagent-test-14306`）
PR：**#6** `kanban/n2-round2-122557` → https://github.com/jjkysy/test-ezagent/pull/6

## 背景：Round1 的 CONFIG-BLOCK 已解

Round1（`docs/e2e/2026-06-26-kanban-phase2-inbound/`）把入站机器全链路证明 live，唯独"真开
PR"被只读 PAT 卡住（#4 CONFIG-BLOCKED）。用户随后更新了 `github.yaml` 的 PAT，对 test-ezagent
有 **admin/push 全写权**（本轮 `gh api repos/... .permissions` 实证 `admin/maintain/push:true`）。
本轮用该写 token（**经 `GH_TOKEN` env 传入、全程 redact，token 不外露**）把 #3-#5 跑绿。

## 结论（一句话）

**入站 DoD 闭环达成（E2E-PASS）**：真 UI 建板/节点 → 真 UI 配 repo+session 触发 PrSync.bind →
真 PAT 真开 PR #6（branch `kanban/n2`）→ **30s poller tick 自动 dispatch `register_pr`** → 板节点
n2 自动挂上 `kind:"pr"` artifact（`ref:"#6"`）。before（产物 0）/after（产物 1）对照证明是 poller
自动挂、非手动。**merged→done 自动推进（#11，可选）未达成**——见下「卡点/发现」。

---

## 服务器健康修复（Step 0，开跑前）

接手时 server 返 500/503（Layer-3 rebase 后 stale）。**只读诊断后**逐项修复（无破坏性、不动他人 WIP）：
1. `mix compile` —— 工作树**能编译**（早前 500 是 reload 中途态）。
2. `mix ecto.migrate` —— rebase 带来一条未跑迁移 `20260627000000`（`Phoenix.Ecto.PendingMigrationError`）→ 跑掉。
3. `mix esbuild ezagent_web` —— esbuild 产物目录被清空（app.js 404）→ 重建 `app.js`（200）。
4. LiveView WS 连接慢/抖（~最长 60–130s 才 `isConnected`）——驱动脚本改 **poll `liveSocket.isConnected()`** 才操作。
   （vite watcher 因 `node_modules/.bin/vite` 损坏 crash-loop，但 server 用 built bundle、非致命噪声。）
确认 Plugins 页 github + kanban 两插件都在（`01`）。**未改任何源码、未提交、未动用户 5176 端口。**

---

## 逐步证据 + #1024 分级

| # | 步骤 | 分级 | 证据（截图/RPC） |
|---|---|---|---|
| 1 | 服务器健康 + Plugins 两插件 | **E2E-PASS** | `01-plugins页-github+kanban两插件在.png`（GitHub「通用网关（经 gh CLI）」+ Kanban 卡片）；CDP `liveConnected:true` |
| 2 | UI 建板 `p2r2-115537` | **E2E-PASS** | `02-建板.png`（空板）；RPC `list_by_role` 实证板存在 |
| 3 | UI 建根节点 | **E2E-PASS** | `03-建根节点.png`（`n1` 产品发心）；CDP `__nodeIds()` = `["n1"]` |
| 4 | UI 建子节点（记 node_id） | **E2E-PASS** | `04-建子节点-记node_id.png`（`n2` 登录表单，真 `window.prompt` 经 CDP 应答）；`__nodeIds()` = `["n1","n2"]` |
| 5 | UI 本图配置填 repo | **E2E-PASS** | `05-本图配置-填repo.png`（GitHub 仓库=`jjkysy/test-ezagent`，header 显示） |
| 6 | UI 绑 session（触发 PrSync.bind） | **E2E-PASS** | `06-绑session.png`（`session://system/default/main`，✓已保存） |
| 7 | poller live（只读 RPC 验） | **DATA-PASS** | `07-PrSync-live-pid.txt`：`PrSyncRegistry` 命中 live pid，`%{alive:true, repo:"jjkysy/test-ezagent", interval:30000}`；board_config 含 repo+session。**session-gated bind 成立** |
| 8 | gh 真开 PR（写 PAT） | **E2E-PASS** | `08-gh开真PR.png`（PR #6 页，public repo 真渲染：Merged←本轮 #11 后状态，branch `kanban/n2-round2-122557`）+ `08-gh开真PR.txt`（`gh pr view`）。token 经 `GH_TOKEN` env、全程 redact |
| 9 | **register 前**节点无 pr artifact（对照） | **E2E-PASS** | `09-poller-tick前-节点无pr-artifact.png`：n2 `产物（0）`、节点 `⚠`（无交付物） |
| 10 | **poller tick 后**节点自动挂 pr artifact（**关键**） | **E2E-PASS** | `10-poller-tick后-节点自动挂pr-artifact.png`：n2 `产物（1）` + `#6`、节点翻 `✓`。**只读 get_tree 实证**：n2.artifacts=`[%{kind:"pr", ref:"#6", url:".../pull/6", tool:"github"}]`，`pr_count=1`。**全自动，无人手填**（09→10 唯一变化是开了 PR #6 + 等一个 tick） |
| 11 | merge → 节点 advance done（**可选**） | **PARTIAL（未推进）** | PR #6 已 merge（`mergedAt` 实证）。`11-merge后-节点advance.png` + 只读 get_tree：n2 仍 `status=:unassigned`、未到 done。**两因**：(a) **入站 poller 不实现 merged→done**（`pr_sync.ex` 只做 inbound register，无 advance/set_status/get_pull）；(b) 手动 `sync_prs`「PR」按钮也未推进本节点（n2 是 `positioning` 阶段、`:unassigned` 未认领 —— `advance_merged_prs`→`set_status done` 对未认领/非 pr 阶段节点不生效）。详见「发现」。 |

---

## 卡点 / 发现（给 Allen / 用户）

1. **merged→done 自动化缺口（架构发现，非本轮可补）**：Phase 2 计划 Task 4 设想 poller 的
   `Sync.advance_merged` 做 merged→done，但**实际实现的 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/pr_sync.ex`
   只有 inbound register**（`list_open_prs`→`register_pr`），**无任何 merged/closed→done 逻辑**。
   merged→done 仍留在 kanban 的**手动** `sync_prs`（连接器 `advance_merged_prs`，UI「PR」按钮）。
   故"merge 后节点自动 done"在当前实现**不成立**——入站只自动登记，不自动收尾。建议 Allen 决策：
   是否把 merged→done 移进 poller（对齐原计划），还是显式保留为手动动作。
2. **手动 `sync_prs` 对未认领/非 pr 阶段节点不推进**：本轮 n2 是 `positioning` 阶段且未认领，
   点「PR」按钮后 status 不变（`set_status done` 需先认领，或节点须 pr 阶段）。这是既有语义，
   非本轮回归——但意味着"挂了 PR 的节点 merge 后自动 done"需要节点先认领 + 处于可推进态。
3. **dev server LiveView 连接慢/抖**：Layer-3 worktree 下 board-detail 路由 LiveView 连接最长
   ~60–130s 才 `isConnected`（vite watcher crash-loop 噪声 + 冷节点）。已用 poll-until-connected 规避，
   但 UI 自动化很慢。非阻断，记一笔。

## sanctioned 路径声明（铁律自查）

- 操作类动作全走 sanctioned 面：world UI（CDP 真点击/填表 → LiveView `world:dispatch` →
  `Ezagent.Invocation.dispatch` → authz）；PR 走 gh CLI（写 token 经 `GH_TOKEN` env）。
- **未用 raw RPC 驱动任何 live-node 操作**；只读 RPC 仅 forensics（Registry/`:sys.get_state`/
  `get_tree`(read action)/`BoardConfig.read`/`list_by_role`）。
- **token 不外露**：写 token 仅从 `~/.ezagent/default/credentials/github.yaml` 读入 `GH_TOKEN` env，
  从不打印；所有命令输出经 `sed -E 's/github_pat_[A-Za-z0-9_]*/REDACTED/'` redact。
- Step 0 健康修复仅跑 migrate + esbuild build（标准 dev 操作）；**未改源码、未提交、未碰用户 5176**。

## 截图 / 证据清单

| 文件 | 内容 | 分级 |
|---|---|---|
| `01-plugins页-github+kanban两插件在.png` | 两插件就位 | E2E-PASS |
| `02-建板.png` | 新建空板 p2r2-115537 | E2E-PASS |
| `03-建根节点.png` | 根 n1 | E2E-PASS |
| `04-建子节点-记node_id.png` | 子 n2 | E2E-PASS |
| `05-本图配置-填repo.png` | repo=jjkysy/test-ezagent | E2E-PASS |
| `06-绑session.png` | bind session→触发 poller | E2E-PASS |
| `07-PrSync-live-pid.txt` | poller live pid + interval（RPC） | DATA-PASS |
| `08-gh开真PR.png` / `.txt` | 真 PR #6（写 PAT） | E2E-PASS |
| `09-poller-tick前-节点无pr-artifact.png` | 对照：n2 产物 0 | E2E-PASS |
| `10-poller-tick后-节点自动挂pr-artifact.png` | **关键：n2 产物 1 #6 自动挂** | E2E-PASS |
| `11-merge后-节点advance.png` | merge 后 n2 未 done | PARTIAL |
