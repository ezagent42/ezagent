# Handoff: D6 — plugin-UI 注册机制:拍缓备案 + kanban 专属文件例外清单(记录型)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** Allen(备案)
> **Tracking:** 开工单 v2 终版 infra 清单 #9 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** confirmed(D6 Allen 已拍「缓」;本文档备案缓的边界 + 由此派生的 PR 边界约定)

## 0. Mission
债②残余(kanban 前端组件出不了 world bundle / `@pages` 手写条目 / conversation 特判)+ mount 折 CompositionBinding——**本轮不实施**,挂 #1394 永久线。本轮任何 PR 不动 plugin-UI 注册**机制**。

## 1. 缓带来的边界约定(v2 切分的判定依据,备案)
D6 落地前,以下文件内容 100% kanban 专属但物理住在 world/web——**约定俗成归 kanban 应用层 PR(PR-K)**,以「例外清单」形式写进 PR-K 描述,#1394 收编时整体搬走:

1. `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx` / `KanbanCanvas.tsx`
2. `apps/ezagent_plugin_world/assets/src/components/unfurl.tsx` 的 kanban 气泡条目(:33-40)
3. `apps/ezagent_web/lib/ezagent_web/controllers/socialware/kanban_share_controller.ex`(P13 合规薄壳)
4. `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex` 的 `@kanban_actions` 字面行(:29;只许加/删 kanban 动作名,不许动注册机制)

**反面**:`WorldLive` / `conversation_actions.ex` / world `world_data` / `PluginPageRegistry` 机制 / 任何 domain/core/web 共享文件——碰了就是 infra,PR-K 拒收。

## 2. #1394 永久线欠账(不做,只记)
- 前端组件出 world bundle(plugin 自带 UI bundle 的注册机制)
- `@pages` 手写条目 → 注册化;conversation 特判溶解
- mount 折 CompositionBinding(挂载与声明式 composition 双轨合一)
- person 挂载的到期/清理策略(mount-person-scope handoff §6 转记)

## 3. Required reading
`docs/together/2026-07-16/handoffs/allen-decisions.md` §D6;`docs/notes/2026-07-15-kanban-layering-debt.md`(债②活清单)。
