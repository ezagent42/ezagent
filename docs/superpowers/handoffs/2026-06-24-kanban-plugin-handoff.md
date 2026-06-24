# Handoff: Kanban 插件（产品自举开发流程看板）

> **Date:** 2026-06-24 · **From:** Claude(with Sy) · **To:** ezagent42/ezagent reviewer + Allen
> **Tracking:** kanban feature PR · **Base:** `upstream/main` @ `d0a7f4f2`
> **Status:** confirmed — code 已提交 `98505fff`，gate 全绿；本 PR=纯 kanban，dev-tooling 走单独 PR。

## 0. Mission
一个**产品自举开发流程看板**：把一个产品从 定位→北极星→痛点→目标用户→体验主张→功能→issue→测试→PR
的 9 阶段固定接力链组织起来，**真相源在 ezagent**，GitHub/Miro/excalidraw 是纯出站投影。一块板=一个
产品开发的单一真相源。

## 1. Required reading
1. Skill `ezagent-developer` — 不变式（P1-P26），gate 你的 PR。
2. `docs/guide/world-coordination.md` — 本工作碰 `world`，必读。
3. `docs/discuss/intro/` — 产品定位（看板=让会话公开的 socialware 方向之一）。
4. dev-together skill — 本 handoff 标准。
5. 设计 spec：`docs/superpowers/specs/2026-06-23-df-prd-mindmap-product-spec.md` 及同目录 impl-*。

## 2. Locked decisions（brainstorm 已定，勿翻案）
| # | 决策 | 值 |
|---|------|----|
| 1 | 9 阶段固定链 | positioning/metric/pain/anchor/ux/feature/issue/test/pr，stage 单调(子≥父) |
| 2 | 真相源 | ezagent 非破坏入站；外部工具纯出站投影 |
| 3 | drop 历史 | 图级别属性(tree.drops)，经唯一 commit/1，不挂某节点 |
| 4 | 每图独立配置 | github repo + miro 板名按图存；token 留全局(以后每用户配) |
| 5 | 挂代码文件 | commit SHA + 路径 → 永久 blob 链接(merge/删分支也能开) |

## 3. Architecture primer
- **Behavior** `Ezagent.Behavior.Kanban`：`use Ezagent.Lifecycle` + `action/3` 宏 + `handle_<action>/2`
  →`{:ok, result, [{:set,:tree,_}]}`；读 `ctx[:read]`，写唯一 `commit/1`；per-node CapBAC(owner/admin)。
- **world 操作面** `ezagent_plugin_world`：`KanbanData`(读，dispatch get_tree)/`KanbanActions`(写，
  dispatch 各动作，ctx 带登录者)；前端 `Kanban.tsx`/`KanbanCanvas.tsx`(react-flow+dagre)。
- **dispatch 链**：前端 `world:dispatch` → `WorldLive` `@kanban_actions` 白名单 → `KanbanActions`
  → `Ezagent.Invocation.dispatch` → Kanban Kind(Behavior)。**人手操作和 agent 走同一条路径**。

## 4. Design & 已落地（本 PR 即完整实现，非分期）
9 阶段链 + R1 插入校验 + 软 gate；认领/状态/挂产物(链接/内容/上传/excalidraw/代码文件)/指标；
drop 砍子树+图级别历史；GitHub 出站(登记PR/出站摘要给CI/轮询merged自动done/建issue/挂SHA文件)；
Miro 出站(httpc binary 防乱码)；CI 沿祖先链评分；session 内看板子视图(chat↔kanban 卡片)+独立页。
**整合到新 main**：reapply(非rebase)，手工整合 world_live/routes/Conversation/router 4 处 + world 加
kanban umbrella dep；arch set_effect_sites 126→127。

## 5. Definition of Done（可展示产物）
- [x] 浏览器 e2e 截图 `docs/superpowers/evidence/assets/*.png`（每图配置/挂代码文件SHA链接/阶段名/
      gate/drop历史侧栏/excalidraw/9阶段接力链树），脚本 `*.mjs` 可复跑。
- [x] gate 全绿：kanban 46/0 + world kanban_data 3/0 + arch 45/0 + mount gate + tsc + vite build + format。
- [x] 回归测试：`drop_subtree` 图级别 drop 历史断言（`kanban_test.exs`）。
- [x] 在 **main 工具链(1.19.5/OTP28)** 上复验（对齐 main，不锁 OTP27）。

## 6. Discuss-first vs Deferred
**Discuss-first（待 Sy/Allen 定，勿先建）：**
- **agent 自动改看板/改状态**：dispatch 链路已就绪；让配好的 agent 调 `kanban.*` = agent 工具/权限
  配置，**Sy 自己拟定**（接 main 在研的 `docs/together/2026-06-24/agent-config-*.md`）。
- **看板 × dev-together 融合**：看板=任务调度器、dev-together=执行器、关键节点回写；评估见
  `docs/discuss/note/2026-06-24-看板与dev-together整合评估.md`。
**Deferred：** 出站带前面产物的 AI 摘要（跟 agent 配合一起改）。
**Never deferred：** 9 阶段链/gate/CapBAC/真相源方向（已落地）。

## 7. Conflict-avoidance
本工作 own 的 world 面：`world_live.ex`(+kanban dispatch/state_for_route)、`routes.ex`(+/plugins/kanban)、
`Conversation.tsx`(+看板tab/view)、`router.ex`、`slot_registry.ex`/`slots.manifest.json`/`main.tsx`
(+kanban_board subcomponent)。碰 world，遵 world-coordination.md。

## 8. Merge model
PR 进 `kanban-clean`（基于 `upstream/main`，勤 rebase）；DoD 满足后由 lead 合 main。

## 9. Gates / 文件 / 开放问题
- Gate：上 §5 全绿。
- 文件：新增 `ezagent_plugin_kanban`(20) + world 6 + docs 68(含 e2e 截图)；改共享 6 文件。
- 开放问题（给 lead/Allen）：world→kanban 的 umbrella 依赖是为过 UndeclaredDep gate；若认为 world 不
  该依赖具体 plugin，可后续把 kanban world 操作面下沉进 `ezagent_plugin_kanban`（更大重构，本 PR 未做）。
