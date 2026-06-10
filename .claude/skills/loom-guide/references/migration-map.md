# Loom → Socialware 迁移地图（提炼版）

> 权威清单：`docs/loom/2026-06-08-loom-to-socialware-migration.md`
> （**在 `docs/loom-socialware-migration` 分支**，基于 feat/loom；本文件是提炼）。
> 权威设计：`docs/superpowers/specs/2026-06-07-socialware-design.md`（rev8，在 main）。

## 定调（设计 rev8 锁死）

> **rewrite directly, reuse `main`, do NOT base on the loom/autoservice branches.**

feat/loom 是单体原型（自带 LLM、飞书、临时用户、前端、SDK 一整套）；socialware
是 main 上的绿地重写。**feat/loom 不整体 merge**。迁移本质：loom 变成 socialware
基座上的 vertical plugin，只保留独有填充物（page 渲染器 + 编排 prompt + page-SDK），
其余改用 main 基础设施。净效果：~7,100 LOC 中 **~1,000 丢弃、~3,500 改写下沉、
~2,600 移植**。

## 概念对应表（loom 轮子 → main 基础设施）

| loom | socialware / main |
|---|---|
| 手写编排循环（decompose→fanout→aggregate→compose） | `Behavior.Turn` 的 `open/dispatch/deliver/compose/settle/cancel` |
| session-rooted 可变页面 + snapshot/fork | `Behavior.Surface` 的 `:surface` slice（不可变版本 + `approved` 指针）；Turn 只能 **dispatch** `surface.put_version`/`surface.approve` 写（locked contract #4） |
| `<span>{json}</span>` scene-card | json-render UI-tree 节点 `%{type, props, children}` |
| LLM 壳（claude_code/deepseek/llm.ex） | flavor 机制（cc / codex / curl），AgentTemplate 声明 |
| 直插 BindingRow 飞书镜像 | `ExternalMirror`（visibility 过滤） |
| `/stream` SSE-from-Publisher | **visibility-gated customer feed**（⚠️ 不复用 SSE） |
| 浏览器临时用户 / loom_signup | customer identity model + session-binding token |
| saved classes（动态 Class） | `Entity.SessionTemplate` / `AgentTemplate` + `template.read/write` |
| operator iframe SessionView | HEEx `PageView` + `SessionViewRegistry` |

## 处置速查（🗑️ 丢弃 ｜ ♻️ 改写下沉 ｜ 📦 移植）

- 🗑️ **全删（~1,000 LOC）**：claude_code / deepseek / llm（→ flavor）、bootstrap、
  feishu、entity/loom 测试桩、snapshots（`:surface` 版本天生不可变）
- ♻️ **编排核心**：loom_orchestrator(715) → `Behavior.Turn` action，策略进
  orchestrator prompt（slot 5）；workers → `turn.deliver(subtask_id, ...)`；
  v0worker → page-worker，页面落库由 Turn compose 时 dispatch `surface.put_version`
- ♻️ **Template/Kind 全套** → SessionTemplate seed（slot 1）+ AgentTemplate
  seed（slot 2），独立 Kind 不再需要
- 📦 **page-SDK**：web_plug 的 SDK 路由 + fetch_proxy + tool* + span→json-render
  → **P4 基座**；prompts 领域知识保留进 AgentTemplate content
- **后置/待 Allen 拍板**：loom_meta_agent（倾向首版不做，用 Routing + fork 覆盖）、
  user_schema + stitch_chat（倾向首版不做）、customer identity 的 anon vs seeded
  （倾向首版 seeded）

web_plug 24 条路由的逐条映射表在权威清单 §3——动 web 面之前必读。

## 落点 phase

| 内容 | phase |
|---|---|
| SDK 路由 + fetch_proxy + tool + span→json-render + 前端 SPA 重建（React+json-render+Sandpack） | **P4** 基座 |
| behavior/template/entity/prompts/application → 新瘦身 `ezagent_plugin_loom` | **P5** 第一个 fused vertical + SW-USE E2E |

首版完成判据（设计 §9 SW-USE 不变式）：一个 settled turn 同时驱动 customer
两个 pane（chat 气泡 + 实时 page）；operator 批准前 customer 看不到任何东西；
`:operator_only` 内容绝不经任何路径到达 customer feed。

## 迁移红线（必守，违反 = 返工）

1. customer feed **只走 visibility-gated query + outbox 事件**——禁止
   `MessageStore.recent_in_session` / 裸 Publisher / 未过滤 ExternalMirror
2. vertical 里**不写编排状态机**——用 `Behavior.Turn`（零 core 代码，设计 §5）
3. page **不自管 mutable 状态**——`:surface` 不可变版本 + 指针；Turn 禁止
   `{:set, :surface}`，只能 dispatch surface 动作（locked contract #4）
4. **不碰** `ezagent_core` / `ezagent_domain_socialware`——vertical 只往
   `ezagent_plugin_loom` 加文件
5. **不复用 `/stream` 的 SSE-from-Publisher**（routing-blind，泄漏 `:operator_only`）
