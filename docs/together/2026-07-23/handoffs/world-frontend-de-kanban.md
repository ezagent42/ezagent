# Handoff: world 前端去 kanban —— tab 内插件渲染走 #1476 manifest（world SPA 不再直接 import 任何插件组件）

> **Date:** 2026-07-23 · **From:** Sy Yao（lead）· **To:** an independent developer (human + cc/codex)
> **Tracking:** 并进 PR #1531（`worktree-world-native-render-registry`）· **Base:** `origin/main` @ `7e3ee6560`
> **Status:** confirmed —— 纯前端 de-hardcode，后端/授权零改动（见 §2）

## 0. Mission
world 的会话面 `Conversation.tsx` 目前**硬 `import {Kanban}` from `ezagent_plugin_kanban/assets`** 并硬编码 `activeMode === "kanban" ? <Kanban>`——world 的 SPA bundle 直接依赖 kanban 的 React 代码。#1476 已经生成了 `assets/src/generated/plugin-page-renderers.tsx`（由各插件 `UiSurfaceProvider` 声明 build 期生成，`pluginPageRenderers["kanban"] → KanbanWorldPage`，而 `KanbanWorldPage` 内部就是渲染 `<Kanban>`）。本任务把 tab 内的插件渲染**改成查这个 manifest 泛化挂载**，让 world 前端**除生成的 manifest 外不再直接 import 任何插件组件**。#1531 已把后端 render-mode 分类器去硬编码；这是它的前端另一半，做完 world 才真正甩掉 kanban。

## 1. Required reading (before writing code)
1. Skill `ezagent-developer` —— 门 PR 的不变式。
2. `docs/guide/world-coordination.md` —— **必读**（本任务动 `world`）。
3. `dev-together` skill —— 本工作流 + handoff 标准（尤其 §DoD 四性质：跨层变更要 parity + e2e 产品证）。
4. #1476 的生成机制：`apps/ezagent_plugin_world/assets/src/generated/plugin-page-renderers.tsx`（生成物，勿手改）+ 它的 generator `mix world.renderers.manifest`；`apps/ezagent_plugin_kanban/assets/src/world_page.tsx`（`KanbanWorldPage` = manifest renderer，props `{component, state, onAction}`）。

## 2. Locked decisions（brainstorm 已定，勿再议）
| # | 决策 | 值 |
|---|------|----|
| 1 | **纯前端** | 只动前端 `.tsx`。后端一律不碰。 |
| 2 | **share 后端 = Allen 的 read-plane 授权车道，禁碰** | `kanban.share_board` action、它的 token 铸造/授权、`Ezagent.Uploads.DownloadToken`、`KanbanShareController`、`kanban_published_read_adapter` **一个字不改**。share 的**统一**是独立 PR（见 `share-backend-unify-allen.md`），给 Allen。 |
| 3 | **share 按钮接线保持 dispatch 现有 `kanban.share_board`** | 前端只把 share 按钮从「world 递 `onShare` 回调」改成 kanban 自己 `onAction("kanban.share_board", {kanban_uri})`（跟旁边 `svg sync_miro` 按钮**一模一样**，line ~200）。**这不是新 share 机制**——是把 UI 接到**现有**动作上，删掉 world→kanban 的 `onShare` 递传。 |
| 4 | **world 侧 share-link 弹窗 = 通用组件** | 保留 world 的 share-link modal，但去 kanban 命名（`kanbanShareLink`→`shareLink`、`data-world-kanban-share-link`→`data-world-share-link`、注释去 kanban），触发改成「`state.share_link` 出现新值就弹一次」（挂载时已有的旧链接不弹）——任何插件产出 share_link 都能用。 |
| 5 | **并进 #1531，一个 PR** | 不新开分支；在 `worktree-world-native-render-registry`（#1531）上加提交。 |

## 3. Architecture primer
- `pluginPageRenderers: Record<string, ComponentType<{component,state,onAction}>>`（生成物）已含 `"kanban" → KanbanWorldPage`；`pluginPageFullBleedFamilies: Set<string>` 含 `"kanban"`。
- `KanbanWorldPage({state,onAction})` 内部 `<Kanban mode={state.kanban_uri?"operate":"config"} state onAction/>`——即**跟 Conversation.tsx tab 内那个 `<Kanban>` 是同一组件**，唯一差别是 manifest 版不传 `onShare`（正因如此才需决策 3：让 share 走 onAction）。
- Conversation.tsx 现状命中面：`import {Kanban,KanbanState}`(L6)、`onKanbanAction` prop（本就是通用 world:dispatch，注释自承 `= onWorkspacePluginAction`）、`handleShareKanban`/`shareRequestedRef`/`kanbanShareLink`（share 逻辑）、`activeMode==="kanban" ? <Kanban ... onShare>`(L~917)、share modal(L~1503)。

## 4. Design & phased plan
**单 PR（并进 #1531），三步：**
1. **`Kanban.tsx`（kanban 插件，自包含 share 按钮）**：share 按钮由 `{onShare && <Button onClick={()=>onShare(uri)}>}` 改成 `<Button onClick={()=>onAction("kanban.share_board",{kanban_uri:uri})}>`；删 `onShare` prop（Kanban + KanbanDetail 签名 + 传递）。全仓仅 Conversation.tsx 一处传 onShare，删除安全。**后端 action 不变。**
2. **`Conversation.tsx`（world，去 kanban）**：删 `import {Kanban,KanbanState}`；`import {pluginPageRenderers} from "../generated/plugin-page-renderers"`；把 `activeMode==="kanban" ? <Kanban>` 换成通用 `pluginPageRenderers[activeMode] ? React.createElement(pluginPageRenderers[activeMode],{component:{id:activeId,type:activeMode},state,onAction:onKanbanAction})`（`data-world-subcomponent={activeMode}`）；删 `handleShareKanban`；share-link 弹窗触发改通用（`state.share_link` 新值检测 + prev-ref，首次只记基线）；去 kanban 命名（decision 4）。`KanbanState` 类型引用换成局部 `{share_link?:string|null}`。
3. **`slots.manifest.json`（L72 `data_source: "EzagentPluginKanban.WorldData"` 手写）**：改由生成（同 #1476 pattern）**或** 若 generator 面太大 → 记 defer 到本 PR 的 open decision，交 lead 裁（decision 4/5 不受影响，但 §5 DoD 该行需 lead 裁 defer）。

**可选（不改行为，去残留命名，lead 裁）**：`onKanbanAction` → `onPluginAction`（touches props + WorldLive 父调用）；`"square-kanban"` 图标映射（generic icon registry，可留）。

## 5. Definition of Done —— closed checklist（四性质）
- [ ] **Parity（跨层，从契约枚举）**：`git grep -n "ezagent_plugin_kanban/assets" apps/ezagent_plugin_world/assets/src/` **只剩** `generated/plugin-page-renderers.tsx` 一处（生成物）——即 world 手写代码里对 kanban assets 的 import == ∅。（证明：grep 输出 + PR diff）
- [ ] **e2e 产品证（user-facing 层，真实 surface）**：agent-browser 驱动——进带看板的 session tab，看板**照常渲染**（建/认领/加节点可操作）+ 点**分享** → share-link modal 弹出 + 链接可复制。留截图（截图是**伴随物非证据**）。
- [ ] **前端回归测试**：vitest 覆盖 tab 内渲染分支走 manifest（`activeMode` 命中 `pluginPageRenderers` → 渲染对应组件）+ share-link 弹窗「新值才弹、旧值不弹」。
- [ ] **share 后端零改动证**：`git diff origin/main -- apps/ezagent_plugin_kanban/lib apps/ezagent_web/lib | grep -c .` 对 share/token/authz 相关文件 == 0（`kanban.ex`/`world_actions.ex` 的 share_board handler、`kanban_share_controller.ex`、`download_token.ex` 未改）。
- [ ] `slots.manifest.json` 去 kanban 手写 data_source（或 lead 已裁 defer 并记 target）。
- [ ] All gates green：arch.scan · doc.scan · uri_query.scan · check_invariants · format · test · `:ezagent_plugin_check` · **前端** `pnpm run build`(exit 0) + `pnpm test`（vitest）。
- [ ] **CI（precommit + check_invariants）green on PR head + rebased on `main`**（machine return gate）。

## 6. Discuss-first vs Deferred
**Clarify-first?** 否——机械改动在 #1476 已定的 manifest 设计内，走 fast path。
**Discuss-first（build 前需 lead 确认）**：无（decisions 已锁）。
**Deferred（flagged+targeted，lead 裁）**：`slots.manifest.json` 生成化——若 generator 改动过大，可 defer 到独立小 PR（target：本解耦路线图 world 尾项）；`onKanbanAction` 改名——可 defer（cosmetic）。
**Never deferred**：删 `import {Kanban}`（load-bearing）、share 后端零改动（红线）、gates、e2e 产品证。

## 7. Conflict-avoidance
Owned surfaces：`apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`、`apps/ezagent_plugin_kanban/assets/src/Kanban.tsx`（仅 share 按钮 + onShare prop）、`apps/ezagent_plugin_world/assets/src/generated/*`（只读）、`slots.manifest.json`。**动 world**：登记进 `docs/guide/world-coordination.md` in-flight registry。与 Task B（share 后端）**零文件重叠**（B 只碰后端 token/authz）。

## 8. Merge model
提交进 `worktree-world-native-render-registry`（#1531）；保持 rebased on `main`；DoD 满足后 **lead** 合 #1531 → `main`。

## 9. Gates / LOC / open questions
Gates：§5。新文件：0（改 2 个 .tsx + 1 json + 1 vitest）。粗估 ~120 LOC。
Open questions for lead：(a) `slots.manifest.json` 生成化 in-PR 还是 defer？(b) `onKanbanAction` 改名要不要顺手做？
