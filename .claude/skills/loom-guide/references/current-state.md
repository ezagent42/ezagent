# Loom 现状权威综述（2026-06-12，对应 feat/loom @ 58504c80）

> 本文件是唯一的"现在是什么样"综述。`docs/loom/` 下的设计文档都是历史切片，
> 有效性见 `doc-timeline.md`。文件级地图（每个模块干什么）在 **loom-developer**
> skill 的 backend-map，本文不重复。

## 1. 一句话

Loom = **每个 session 一支固定 agent 团队**（编排器 + 2 主题 worker + 页面 worker
+ preview-AI worker + 团队管家）+ **一个 vendored Next.js 前端**，访客对话驱动两件
事并行：聊天侧出 scene-card 回复，页面侧实时生成/增强一张 React 页面；页面可发布 →
分享快照 → fork，发布页自带 Stitch 聊天 / AiSpot 卡片 / "为你推荐"意图推荐。

## 2. 团队（每 session 6 套 Behavior/Entity/Template 三件套）

| 角色 | URI | 职责 |
|---|---|---|
| orchestrator | `loomorch_<sid>` | 每轮：拆解 → fan-out → 聚合 → 组 scene-card |
| worker ×2 | `loomworker_<sid>_<theme>` | 主题内容片段（预制 policy / company，可自定义） |
| v0worker | `loomv0_<sid>` | in-session AI **页面**生成（出 JSX 代码块） |
| **stitchworker**（06-10 起） | `loomstitch_<sid>` | preview 侧 AI（Stitch 聊天 + AiSpot 卡片），**@-only**：靠 `addressed_to_self?` loop-guard，编排器 decompose 永远调不到它；本质 DeepSeek-backed |
| meta agent | `loommeta_<sid>` | 团队管家：@自然语言动态改 team |

共同契约：mention-gated（默认 `system_default` 路由只投被 @ 的 agent + User 成员，
worker↔worker 串话结构上不可能）、ref_id 回执、零 spawn-time 配置注入（roster 运行时
从 session members 发现，theme 从 URI 名末段读）。装配走 `session.loom` Template
Class（`Team.ensure_team/1` 幂等 reconciler）。

⚠️ loom Behavior 全部用旧 `use Ezagent.Behavior` 引擎（**不是** Lifecycle）——
这是与 ezagent-developer 指引的刻意分歧，不要"顺手现代化"，详见 loom-developer
的 gotchas 第一条。

## 3. 一条消息的全链路（编排侧）

1. 浏览器 SPA（`GET /loom/:ws/:sid`）`POST /loom/api/:ws/:sid/messages`
2. WebPlug 以访客身份 dispatch `chat.send` 进 `session://loom/<ws>/<sid>`
3. 消息 @ 了 `loomorch_<sid>` → 拆解（`LLM.chat`）→ 每个子任务 @ 对应 worker
   并带 `ref_id` → worker 产出片段回 ref_id → 收齐（或 dead-worker 超时兜底）
   → 组合 scene-card `<span>{json}</span>` → `chat.send` 回 session
4. 浏览器 `GET /stream`（SSE）收 session 消息流渲染卡片；v0worker 的页面生成
   进度走 `loom:gen_progress:<group>` PubSub → 同一条 SSE

LLM 后端：5 个编排侧 Behavior 走 `LLM.chat/2`（`LOOM_LLM_BACKEND` 开关，
boot 时生效，默认 claude_code）；stitchworker 与 `/intent` 始终 DeepSeek。
细节归 loom-developer backend-map §2。

## 4. 消费侧（preview / 发布 / 分享 / fork）

- **publish**：创建不可变 Template Class（`session.pub_<hex>`）+ 冻结 share
  snapshot。06-11 起带 **self-heal**：orchestrator 死了按需 respawn；冻结内容
  取最新 page_update 消息（而非 slice），保证快照与编辑器所见一致
- **分享**：`POST /snapshot` 出 16-hex token → `GET /snapshot/:token` 只读查看
  （06-11 起返回 `stitch_config`，恢复 bar/accent 外观）
- **fork**：`/p/:token/open` + `/p/:token/fork` 两阶段，从快照模板起新 session
- **消费会话标记**（06-10，`consumer_session.ex`）：`/p/:token/open` 从发布物
  mint 的 per-访客只读会话（`pub_<hex>`）在**创建点**打标——按名字或按有无 v0
  判都不可靠——决定 operator 端不显示 loom 编辑视图 tab
- **Stitch / AiSpot**（06-10 重构）：不再 WebPlug 直连 DeepSeek；每句对话/每次 ✨
  由 WebPlug 包成 `@loomstitch_<sid>` 消息派进 session，worker 回
  `<span type="stitch_reply">{...}</span>`——**对话进 MessageStore（session 可见
  + 持久化），取代旧 `loom_stitch_chats.json`**
- **意图推荐**（06-11）：session-less `POST /loom/intent`——自然语言意图 + 页面
  目录 → DeepSeek 硬选 3 个产品 + pitch，驱动"为你推荐"轮播
- **知识库**：编辑者写一段 Markdown，作为 Stitch/AiSpot grounding，发布随模板
  带走、fork 复制

## 5. 演化简史（详注见 doc-timeline.md）

| 期 | 标志 | 留下了什么 |
|---|---|---|
| Hello demo（05-27 PRD） | 多 agent 编排 demo 立项 | 编排器+worker 角色划分、飞书镜像 |
| page-builder spec（05-28） | 41 组件 schema-driven 设计 | **大部分被推翻**（实际走 vendored ai-ui-builder + AI 生成 JSX + Sandpack） |
| 前端集成 + SDK bridge（05-29） | `forward "/loom"` 唯一触碰、postMessage 桥 | WebPlug、SDK v1 |
| session-rooted 重设计（06-01） | v0worker、page_update span、mention 解析 | 现行编排形态 |
| team-manager + saved classes（06-03 前后） | loommeta、存为模板、cleanup 传播 | saved_classes、ghost-session 过滤 |
| snapshots/Stitch/self-signup（06-05） | 分享快照、fork 两阶段、Stitch v1、loom_signup | 消费侧骨架 |
| v0 streaming + knowledge（06-09/10） | SSE 生成进度、知识库、LLM 开关 | `llm.ex`、`knowledge.ex` |
| socialware 迁移定调（06-08） | "rewrite directly, do NOT base on loom branch" | `migration-map.md` |
| **stitch worker 重构（06-10/11）** | Stitch/AiSpot 入 session（`loomstitch` worker）、consumer_session、`/intent`、publish self-heal、loom-developer skill | 现行消费侧；**无 docs/loom 设计文档，权威是代码 + loom-developer skill** |

main 侧同步推进：socialware **P4 已落地**（#732）、P5 前置 config-evolve（#733）
——迁移 phase 状态见 `migration-map.md`。
