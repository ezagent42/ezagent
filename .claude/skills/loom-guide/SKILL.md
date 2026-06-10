---
name: loom-guide
description: >-
  Use whenever working on or asking about Loom — the multi-agent page-builder
  vertical living in apps/ezagent_plugin_loom (feat/loom branch). Triggers:
  touching any file under apps/ezagent_plugin_loom/, the /loom web surface
  (WebPlug routes, SSE stream, signup), the loom team roles (loomorch /
  loomworker / loomv0 / loommeta), Stitch / share snapshot / fork /
  saved-class templates / knowledge base, the vendored Next.js frontend
  (priv/static/loom_ui, source repo github.com/ezagent42/loom), the
  LOOM_LLM_BACKEND switch (claude_code vs deepseek), or planning the
  loom → socialware migration. Also trigger when introducing Loom to a
  newcomer — this skill carries the only authoritative current-state
  overview (the design docs under docs/loom/ are a chronological pile
  that superseded each other several times).
---

# loom-guide

**Loom** 是跑在 ezagent 上的第一个「多 agent 编排 + AI page-builder」vertical：
访客在网页里跟一个编排器对话，编排器拆解意图、并发派给主题 worker、聚合后回一张
scene-card；同时一个 page-worker 实时生成/增强一张 React 页面，可发布、分享快照、
fork。整个东西是 `apps/ezagent_plugin_loom`（~8,000 LOC）+ 一个 vendored Next.js
前端 + 11 个插件外触碰点。

> ⚠️ **先校准两件事**，否则后面全偏：
> 1. Loom 活在 **`feat/loom` 分支**（PR #480），**不会整体 merge 进 main**。
>    main 上的 socialware 是它的绿地重写，loom 的能力按
>    `references/migration-map.md` 迁移过去。
> 2. `docs/loom/` 下的 11 份文档是**按时间叠加的设计演化记录**，互相推翻过几轮
>    （Hello demo → page-builder → session-rooted → snapshots/Stitch）。**不要把
>    任何一份单独当作现状**；现状以 `references/current-state.md` 为准，每份旧文档
>    的有效性标注在 `references/doc-timeline.md`。

## 30 秒心智模型

一条消息的全链路（详图在 `references/current-state.md`）：

```
浏览器 SPA (/loom/:ws/:sid)
  → POST /loom/api/:ws/:sid/messages          (WebPlug, plugin→web 唯一触碰)
  → dispatch chat.send 进 session://loom/<ws>/<sid>
  → mention-gated 默认路由（只投给被 @ 的 agent + User 成员）
  → @loomorch_<sid> 收到 → LLM.chat 拆解 → fan-out @loomworker_<sid>_<theme> 子任务
  → worker 各自 LLM.chat → 带 ref_id 回 orchestrator → 聚合 → 组 scene-card
  → chat.send 回 session → GET /stream (SSE) 推回浏览器渲染卡片
  （并行：@loomv0_<sid> 生成 JSX 页面 → user_schema ops → preview/publish/分享）
```

## 按受众选路径

| 你是谁 | 读什么 |
|---|---|
| **新人/评审，想知道 loom 是什么** | `current-state.md` → `doc-timeline.md`，按需看 `docs/loom/PRD.md`（产品动机，注意已部分过时） |
| **在 feat/loom 上写代码** | `current-state.md` → `agent-roles.md` / `web-surface.md` / `persistence-map.md` → 动手前过一遍 `pitfalls.md`（已知债 + 事故根因） |
| **做 loom → socialware 迁移** | `migration-map.md`（处置清单 + 红线）→ 对照 main 上的 `docs/superpowers/specs/2026-06-07-socialware-design.md`（rev8，权威设计） |
| **改前端 / SDK** | `frontend-and-sdk.md`（源码仓库、vendor 流程、SDK v1/v2） |
| **调 LLM 后端 / prompt** | `llm-backends.md`（LOOM_LLM_BACKEND 开关 + Stitch 的例外） |

## 易混淆词消歧（loom 专属，叠加在 GLOSSARY.md 之上）

| 词 | loom 里的意义 | 不要混淆 |
|---|---|---|
| **snapshot** | share snapshot（发布/分享时冻结的不可变快照，`loom_snapshots.json`） | ezagent 的 Kind snapshot（状态持久化，SnapshotStore） |
| **template** | saved class（"存为模板"动态生成的 Template Class，`session.<name>`） | 既有的 Template Class 静态声明（如 `session.loom`） |
| **worker** | session 成员 agent（`loomworker_<sid>_<theme>`） | OTP worker / GenServer |
| **v0 / v0worker** | in-session AI 页面生成 agent（名字源于 v0.dev，现已自建，与 v0.dev 无关） | 版本号 v0 |
| **Stitch** | preview 页右下角的辅助聊天助手（独立 DeepSeek 直连） | 编排器/worker 体系（Stitch 完全不进 session 编排） |
| **publish** | loom 的页面发布（创建不可变 Class + share snapshot） | Phoenix PubSub publish |

## File layout

```
loom-guide/
├── SKILL.md                  ← 导航 + 30 秒心智模型（本文件）
└── references/
    ├── current-state.md      ← 现状权威综述：角色体系 + 全链路 + 演化简史
    ├── agent-roles.md        ← 5 套 Behavior/Entity/Template 三件套 + 命名/路由契约
    ├── web-surface.md        ← WebPlug 26 条路由 + 插件外触碰面清单
    ├── frontend-and-sdk.md   ← 前端源码仓库 + vendor dist 流程 + SDK v1/v2
    ├── persistence-map.md    ← 数据归宿地图（5 个旁路 JSON + Kind snapshot）
    ├── llm-backends.md       ← LOOM_LLM_BACKEND 开关 + Stitch/AiSpot 例外
    ├── pitfalls.md           ← 事故根因 + 已知债（23 个 gate 欠账、plugin 契约违规）
    ├── doc-timeline.md       ← docs/loom/ 11 份文档的时间线 + 有效性标注
    └── migration-map.md      ← loom → socialware 处置清单 + 迁移红线
```

写 loom 代码同时要遵守 ezagent 全局约束 — **先 load `ezagent-developer` skill**
（设计原则 P1-P27、dispatch 不变式、plugin 契约）。本 skill 只补 loom 特有的部分。
