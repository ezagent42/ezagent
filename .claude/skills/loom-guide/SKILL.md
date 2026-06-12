---
name: loom-guide
description: >-
  Use for Loom orientation, documentation archaeology, project status, and
  the loom → socialware migration — NOT for writing loom code (that is
  loom-developer's job; load that skill instead when touching .ex files
  under apps/ezagent_plugin_loom/). Triggers: introducing Loom to a
  newcomer or reviewer ("loom 是什么"), deciding which docs/loom/*.md
  design doc is still valid (they superseded each other several times),
  checking known debts / branch state of feat/loom (gate debts, what will
  and will not merge to main), where loom data lives (5 bypass JSONs vs
  MessageStore vs Kind snapshots), or planning/executing the loom →
  socialware migration (disposal map, red lines, phase landing status on
  main). This skill carries the only authoritative current-state overview
  and the doc-validity timeline.
---

# loom-guide

**Loom** 是跑在 ezagent 上的「多 agent 编排 + AI page-builder」vertical（feat/loom
分支，PR #480）：访客跟编排器对话，编排器拆解意图、并发派给主题 worker、聚合后回
scene-card；同时 page-worker 实时生成/增强一张 React 页面，可发布、分享快照、fork；
发布页自带 preview 侧 AI（Stitch 聊天 + AiSpot 卡片 + 意图推荐）。

## 跟 loom-developer 的分工（先看这个，别加载错）

| 你要做什么 | 用哪个 skill |
|---|---|
| 写/改/调试 loom 代码（Behavior、WebPlug、前端、SDK、prompt） | **`loom-developer`**（backend-map / frontend-and-sdk / gotchas / recipes） |
| 向新人/评审介绍 loom；判断哪份设计文档还有效；查项目级债和分支状态；做 socialware 迁移 | **本 skill** |

两边互补不重复：loom-developer 管"怎么写"，本 skill 管"这是什么、从哪来、
到哪去"。写代码前两个都该过一眼的只有一处——`pitfalls.md` 的事故根因
（ghost session / 双 instantiate）目前只在本 skill。

> ⚠️ **先校准两件事**：
> 1. Loom 活在 **feat/loom 分支**，**不会整体 merge 进 main**。main 上的
>    socialware 是绿地重写（P4 已落地），loom 能力按 `references/migration-map.md`
>    迁移过去。
> 2. `docs/loom/` 下的文档是**按时间叠加的设计演化记录**，互相推翻过几轮。
>    **不要把任何一份单独当作现状**；现状以 `references/current-state.md` 为准，
>    每份旧文档的有效性标注在 `references/doc-timeline.md`。

## 30 秒心智模型

```
浏览器 SPA (/loom/:ws/:sid)
  → POST /loom/api/:ws/:sid/messages → dispatch chat.send 进 session
  → mention-gated 默认路由（只投给被 @ 的 agent + User 成员）
  → @loomorch_<sid> 拆解 → fan-out @loomworker_<sid>_<theme> → 聚合 → scene-card
  → chat.send 回 session → GET /stream (SSE) 推回浏览器
  （并行：@loomv0_<sid> 生成 JSX 页面 → 发布/分享/fork；
   发布页的 Stitch/AiSpot 走 @loomstitch_<sid> worker，对话进 MessageStore）
```

团队 = 每 session 6 套三件套：orchestrator + 2 themed worker + v0worker（页面）
+ stitchworker（preview 侧 AI，2026-06-10 起）+ meta agent（团队管家）。
文件级细节见 loom-developer 的 backend-map。

## 易混淆词消歧（loom 专属，叠加在 GLOSSARY.md 之上）

| 词 | loom 里的意义 | 不要混淆 |
|---|---|---|
| **snapshot** | share snapshot（发布/分享时冻结的不可变快照，`loom_snapshots.json`） | ezagent 的 Kind snapshot（状态持久化，SnapshotStore） |
| **template** | saved class（"存为模板"动态生成的 Template Class，`session.<name>`） | 既有的静态 Template Class（如 `session.loom`） |
| **worker** | session 成员 agent（`loomworker_<sid>_<theme>`） | OTP worker / GenServer |
| **v0 / v0worker** | in-session AI 页面生成 agent（名字源于 v0.dev，已自建，与 v0.dev 无关） | 版本号 v0 |
| **Stitch** | preview 页的辅助 AI。2026-06-10 起是 session 里的 `loomstitch_<sid>` worker（@-only，编排器永远调不到它），对话进 MessageStore | 编排 worker 体系（Stitch 不参与 decompose/fan-out） |
| **消费会话** | `/p/:token/open` 从发布物 mint 的 per-访客只读会话（`consumer_session` 标记，按创建来源判定） | 创作会话（从 `session.loom`/手存模板实例化，有编辑视图） |
| **publish** | loom 的页面发布（创建不可变 Class + share snapshot） | Phoenix PubSub publish |

## File layout

```
loom-guide/
├── SKILL.md                  ← 导航 + 心智模型 + 与 loom-developer 的分工（本文件）
└── references/
    ├── current-state.md      ← 现状权威综述：角色体系 + 全链路 + 演化简史
    ├── persistence-map.md    ← 数据归宿地图（旁路 JSON / MessageStore / Kind snapshot）
    ├── pitfalls.md           ← 事故根因 + 项目级债（gate 欠账、分支管理）
    ├── doc-timeline.md       ← docs/loom/ 文档时间线 + 有效性标注
    └── migration-map.md      ← loom → socialware 处置清单 + 红线 + phase 落地状态
```

写 loom 代码同时要遵守 ezagent 全局约束 — load `ezagent-developer`（设计原则、
dispatch 不变式、plugin 契约）+ `loom-developer`（loom 特有 landmines）。
