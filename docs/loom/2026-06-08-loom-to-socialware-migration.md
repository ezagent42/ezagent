# Loom → Socialware 迁移文档

> **状态:** 迁移规划 (rev1, 2026-06-08)
> **分支:** `docs/loom-socialware-migration`（基于 `feat/loom`）
> **目标读者:** 把 `feat/loom` 的能力迁到 `main` 上 socialware 基座的工程师
> **权威设计:** `docs/superpowers/specs/2026-06-07-socialware-design.md`（rev8, Allen，存在于 `main`，不在本分支）

---

## 0. TL;DR

`feat/loom` 是一个**单体原型**：自带 LLM 后端、飞书集成、临时用户系统、Next.js 前端、page-SDK 一整套。
`main` 上的 **socialware** 是它的**绿地重写**——把 loom 里「通用的」能力下沉成了基础设施。

迁移方向（设计 rev8 第 4 行锁死）：

> **rewrite directly, reuse `main`, do NOT base on the loom/autoservice branches.**

所以本分支**不整体 merge 进 main**。迁移的本质是：

> **loom 从「独立 app」变成「socialware 基座上的一个 vertical plugin」（`ezagent_plugin_loom`），
> 只保留它独有的填充物（page 渲染器 + 编排 prompt + page-SDK），其余全部丢弃、改用 main 的基础设施。**

净效果：~7100 LOC lib 中，**~1000 丢弃、~3500 改写下沉、~2600 移植**。

---

## 1. 两边的对应关系（loom 概念 → socialware 基础设施）

| loom 自己造的轮子 | socialware / main 上的替代 | 来源 |
|---|---|---|
| 手写 orchestrator 编排循环（decompose→fanout→aggregate→compose） | `Behavior.Turn` + `:turns` slice 的 action 集 | `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex` |
| session-rooted 可变页面 + snapshot/fork | `Behavior.Surface` 拥有 `:surface` slice（不可变版本 + `approved` 指针）；**`Behavior.Turn` 不直接写 `:surface`，通过 dispatch `surface.put_version`/`surface.approve` 写**（locked contract #4） | `.../behavior/surface.ex` |
| `<span>{json}</span>` scene-card | json-render UI-tree 节点 `%{type, props, children}` | 设计 §4.2 |
| DeepSeek / 本地 CC 壳 + LLM 分发 | flavor 机制（`cc` / `codex` / `curl`） | `ezagent_plugin_cc` 等 |
| 直插 BindingRow 镜像飞书 | `ExternalMirror`（带 visibility 过滤的 simple-mirror 成员） | `ezagent_plugin_feishu` + `ExternalMirror` |
| `/stream` SSE-from-Publisher 喂前端 | **visibility-gated customer feed**（⚠️ 不复用 SSE） | `.../socialware/customer_feed.ex` + `customer_outbox.ex` |
| 浏览器临时用户 | customer identity model + session-binding token | `.../socialware/customer_auth.ex`（§4.4 契约） |
| 存为模板（Class 级动态生成） | `Entity.SessionTemplate` / `AgentTemplate` + `template.read/write` | `ezagent_domain_instance_message` |
| operator 端 iframe SessionView | operator HEEx `PageView` + `SessionViewRegistry` | `.../ezagent_domain_socialware/page_view.ex` |

---

## 2. 文件级迁移清单

处置图例：🗑️ 丢弃 ｜ ♻️ 改写下沉 vertical ｜ 📦 移植（改接 socialware）

### 2.1 LLM 后端 — 全部丢弃

| 文件 | LOC | 职责 | 处置 → 目标 |
|---|---|---|---|
| `lib/ezagent/claude_code.ex` | 487 | 本地 CC 聊天补全壳 | 🗑️ → flavor `cc`（`ezagent_plugin_cc`） |
| `lib/ezagent/deepseek.ex` | 106 | DeepSeek HTTP 壳 | 🗑️ → flavor 机制 |
| `lib/ezagent/llm.ex` | 57 | 后端分发层 | 🗑️ → flavor 由 AgentTemplate 声明 |

### 2.2 集成/引导 — 丢弃（用 socialware 基座）

| 文件 | LOC | 职责 | 处置 → 目标 |
|---|---|---|---|
| `lib/ezagent/bootstrap.ex` | 149 | per-visitor 建 session + 临时用户 + 绑飞书 | 🗑️ → `SessionTemplate.instantiate` + `customer_auth.ex` |
| `lib/ezagent/feishu.ex` | 81 | 直插 BindingRow 镜像飞书 | 🗑️ → `ezagent_plugin_feishu` + visibility-filtered `ExternalMirror` |
| `lib/ezagent/entity/loom.ex` | 29 | fixed-reply 测试 bot | 🗑️ 纯测试桩 |
| `lib/ezagent/snapshots.ex` | 67 | share snapshot 存储 | 🗑️ → `:surface` 版本天生不可变，snapshot = 指针快照 |

### 2.3 编排 Behavior — 改写下沉到 `Behavior.Turn`（核心）

> ⚠️ loom 手写的编排循环**全部丢弃**，改用 `Behavior.Turn` 的 `open/dispatch/deliver/compose/settle/cancel`；
> decompose/compose 策略 → orchestrator AgentTemplate prompt（slot 5）。

| 文件 | LOC | 职责 | 处置 → 目标 |
|---|---|---|---|
| `lib/ezagent/behavior/loom_orchestrator.ex` | **715** | 分解→扇出→聚合→合成 scene-card | ♻️ → `Behavior.Turn` action；策略 → orchestrator prompt |
| `lib/ezagent/behavior/loom_worker.ex` | 229 | 内容片段 worker（回 ref_id） | ♻️ → nl/content worker，产出走 `turn.deliver(subtask_id, card_ref)` |
| `lib/ezagent/behavior/loom_v0_worker.ex` | 269 | in-session AI **页面**生成 worker | ♻️ → page-worker，`turn.deliver` 一个 UI-tree fragment；page 落库由 `Behavior.Turn` 在 `compose` 时 **dispatch `surface.put_version`** 完成（worker 不直接碰 `:surface`，§4.2 / contract #4） |
| `lib/ezagent/behavior/loom.ex` | 250 | DeepSeek scene-card bot（`:say`/`:web`） | ♻️ 编排丢弃；degenerate 单 bot → 零 subtask 的 turn |
| `lib/ezagent/behavior/loom_meta_agent.ex` | 489 | @自然语言动态改 team | ♻️ **后置/待定** → vertical policy module（slot 6）或 `Routing`+fork（见 §4） |

### 2.4 Kind / Template — 改写成 socialware 声明（slot 1/2）

| 文件 | LOC | 职责 | 处置 → 目标 |
|---|---|---|---|
| `lib/ezagent/template/loom_session.ex` | **527** | Session Template Class：组装 team + join | ♻️ → **SessionTemplate seed（slot 1）**：`Behavior.Chat + Turn + Surface` + roster + 内部 routing 规则 |
| `lib/ezagent/template/loom_orchestrator.ex` | 96 | orchestrator flavor 声明 | ♻️ → **AgentTemplate seed（slot 2）**，flavor 改 cc/codex |
| `lib/ezagent/template/loom_worker.ex` | 102 | worker flavor 声明 | ♻️ → AgentTemplate seed |
| `lib/ezagent/template/loom_v0_worker.ex` | 95 | page-worker flavor 声明 | ♻️ → AgentTemplate seed |
| `lib/ezagent/template/loom_agent.ex` | 113 | 通用 pure-spawn flavor | ♻️ → AgentTemplate seed |
| `lib/ezagent/template/loom_meta_agent.ex` | 93 | team-manager flavor 声明 | ♻️ 随 meta_agent 去留 |
| `lib/ezagent/entity/loom_orchestrator.ex` | 30 | orchestrator Kind | ♻️ → 不需独立 Kind，AgentTemplate × role 即可 |
| `lib/ezagent/entity/loom_worker.ex` | 27 | worker Kind | ♻️ → AgentTemplate × role |
| `lib/ezagent/entity/loom_v0_worker.ex` | 27 | page-worker Kind | ♻️ → AgentTemplate × role |
| `lib/ezagent/entity/loom_meta_agent.ex` | 38 | team-manager Kind | ♻️ 随 meta_agent 去留 |
| `lib/ezagent/saved_classes.ex` | 358 | 存为模板（Class 级动态生成） | ♻️ **后置** → `template.read/write`，动态 Class 生成多半丢弃重做 |

### 2.5 前端运行时 / page-SDK — 移植到 P4 foundation + vertical

> ⚠️ 红线：**不要复用 `/stream` 的 SSE-from-Publisher**（routing-blind，泄漏 `:operator_only`），
> 改读 visibility-gated feed（设计 §4.3 codex rev5-CRITICAL）。

| 文件 | LOC | 职责 | 处置 → 目标 |
|---|---|---|---|
| `lib/ezagent/web_plug.ex` | **1109** | HTTP 入口 + 24 条路由 | 📦 **拆解**（见 §3 路由映射表） |
| `lib/ezagent/span.ex` | 162 | raw 输出 → `<span>{json}</span>` 归一化 | 📦♻️ → UI-tree fragment 归一化（json-render 节点）。概念保留，格式换 |
| `lib/ezagent/fetch_proxy.ex` | 275 | AI 页面白名单 HTTP 代理 | 📦 → P4 `code` 节点（Sandpack 沙箱）的受控 fetch |
| `lib/ezagent/tool.ex` | 75 | page-SDK tool 契约 | 📦 → P4 page-runtime tool 机制 |
| `lib/ezagent/tool_registry.ex` | 150 | boot 期 tool 注册表 | 📦 → P4 page-runtime |
| `lib/ezagent/tools/echo.ex` | 29 | smoke-test tool | 📦 → 示例 tool（可选） |
| `lib/ezagent/tools/now.ex` | 55 | 服务端时间 tool | 📦 → 示例 tool（可选） |
| `lib/ezagent/plugin_loom/view/loom_session_view.ex` | 78 | operator iframe SessionView 标签 | ♻️ → 已有 `page_view.ex` + `SessionViewRegistry` |
| `lib/ezagent/prompts.ex` | 436 | scene-card system prompt + persona | 📦 **保留领域知识** → AgentTemplate content（slot 2/5），代码壳丢弃 |
| `lib/ezagent/temp_user.ex` | 90 | 浏览器临时用户生命周期 | 📦♻️ → customer identity model（§10 待定），逻辑参考落到 `customer_auth.ex` |
| `lib/ezagent/user_schema.ex` | 102 | per-session 用户操作序列 | 📦 **后置** → vertical 特有，或并入 `:surface`（见 §4） |
| `lib/ezagent/stitch_chat.ex` | 80 | preview 页右下角辅助聊天 | 📦 **后置** → vertical 可选功能（见 §4） |
| `priv/static/loom_ui/*` | — | Next.js static export + Sandpack | 📦 **重建不直接搬** → P4 React+json-render SPA，扔 SSE 接 gated feed |

### 2.6 Plugin 框架 + 测试

| 文件 | LOC | 处置 → 目标 |
|---|---|---|
| `lib/ezagent_plugin_loom/application.ex` | 205 | ♻️ → 新 `ezagent_plugin_loom` 瘦身 Application：注册 template seeds + node types + tools，删 fixed-bot 逻辑 |
| `mix.exs` | — | ♻️ → 依赖改指 `ezagent_domain_socialware`，删自带 LLM/feishu |
| `test/**` | — | ♻️ → 按 socialware 契约 TDD 重写 |

---

## 3. `web_plug.ex` 路由拆解映射（最关键的一块）

`web_plug.ex` 的 24 条路由是 loom 跟前端的全部接口。拆成三组：

| loom 路由 | 处置 | socialware 目标 |
|---|---|---|
| `POST /api/:ws/:sid/messages` | ♻️ | customer 入站 → `Chat` 持久化 → routing `{:from customer}→orchestrator` |
| `GET /api/:ws/:sid/history` | ♻️ | `customer_feed.ex` 的 gated query（`:customer_visible` ∧ settlement `:committed`） |
| `GET /api/:ws/:sid/stream` | 🗑️→♻️ | **不复用 SSE-from-Publisher**；改 `customer_channel.ex`/`customer_socket.ex` 读 outbox 投递事件 |
| `POST /api/:ws/:sid/stop` | ♻️ | `turn.cancel` |
| `POST /api/:ws/:sid/publish` | ♻️ | `turn.settle` → `:surface.approved` 指针前进 |
| `POST /api/:ws/:sid/snapshot` | ♻️ | `:surface` 版本不可变，snapshot = 记录指针 |
| `POST /p/:token/fork` `POST /p/:token/open` `GET /snapshot/:token` | ♻️ | 指针操作 + SessionTemplate fork（设计 §8「Separate pages = fork the SessionTemplate」） |
| `POST /save-as-template` `GET /templates` `DELETE /templates/:name` `POST /templates/:name/spawn` `GET /published` | ♻️ | `template.read/write` + `SessionTemplate` |
| `GET/POST /user-schema` | 📦 后置 | vertical 特有（见 §4） |
| `GET/POST /stitch` | 📦 后置 | vertical 辅助聊天（见 §4） |
| `POST /fetch` | 📦 | `fetch_proxy.ex` → P4 `code` 节点受控 fetch |
| `POST /tool` | 📦 | `tool_registry.ex` → P4 page-runtime tool |
| `POST /upload` `GET /resource` | 📦 | P4 page-runtime 资源能力（按需） |
| `GET /whoami` | ♻️ | session-binding token → customer identity（§4.4） |
| `GET /*_path` | 📦 | SPA fallback → React SPA host |

---

## 4. 待 Allen 拍板的开放项

迁移前需要决定，否则首版 vertical 边界不清：

1. **`loom_meta_agent`（@自然语言动态改 team）是否纳入首版？**
   - 选项 A：纳入 → vertical 的 mode/policy module（slot 6）。
   - 选项 B（倾向）：首版不做，用 `Routing` 规则 + SessionTemplate fork 覆盖常见场景，meta_agent 后置。

2. **`user_schema`（per-session 可增强模型）+ `stitch_chat`（辅助聊天）是否纳入首版？**
   - 这两个是 loom 特有的 page 增强体验，socialware 设计未覆盖。
   - 倾向：首版**不做**，先跑通「一个 turn 同时驱动 chat 气泡 + 实时 page」的核心 fusion（SW-USE E2E），这两个作为 vertical 增量。

3. **customer identity model（§10 open decision）**：session-binding token 背后是 anon/synthetic 还是 seeded user？
   - 倾向（设计 §10）：首个 SW-USE E2E 用 seeded user，anon 模型在前端 phase 后。
   - `temp_user.ex` 的逻辑作为 anon 模型的参考。

---

## 5. 落点与 phase 对照

对照 `main` 上 socialware 的进度（已落地 P1/P2/P3/P6，详见设计 §11）：

| 迁移内容 | 落点 phase |
|---|---|
| `web_plug` SDK 路由 + `fetch_proxy` + `tool*` + `span`→json-render + 前端 SPA 重建 + Sandpack | **P4** 基座（一次性） |
| `behavior/*` 编排 + `template/*` + `entity/*` + `prompts` + `application` → `ezagent_plugin_loom` | **P5** 第一个 fused vertical + SW-USE E2E |
| 🗑️ 直接删：3 LLM 壳 + bootstrap + feishu + 测试 bot + snapshots（~1000 LOC 净删） | — |

**首版完成判据**（设计 §9 SW-USE 不变式）：一个 settled turn 同时驱动 customer 两个 pane（chat 气泡 + 实时 page）；copilot/takeover 下 customer 在 operator 批准前看不到任何东西，且 agent 的 `:operator_only` 内容**绝不经任何路径**（live/replay/Publisher/ExternalMirror）到达 customer feed。

---

## 6. 迁移红线（必守）

1. **customer feed 只走 visibility-gated query + outbox 事件**——禁止 `MessageStore.recent_in_session` / 裸 Publisher / 未过滤 ExternalMirror（codex rev5-CRITICAL）。
2. **vertical 里不写编排状态机**——用 `Behavior.Turn` 的 action，否则违反「零 core 代码」（设计 §5）。
3. **page 不自管 mutable 状态**——走 `:surface` 不可变版本 + 指针，fork/snapshot/rollback 全是指针操作。`:surface` 由 `Behavior.Surface` 拥有；**`Behavior.Turn` 只能 dispatch `surface.put_version`/`surface.approve` 写它，禁止 `{:set, :surface}`**（Lifecycle 只能改自己的 slice，sibling slice 在 `ctx` 里只读，locked contract #4）。
4. **不碰 `ezagent_core` / `ezagent_domain_socialware`**——vertical 只往 `ezagent_plugin_loom` 加文件（设计 §5 naming locked）。
5. **不复用 `/stream` 的 SSE-from-Publisher**——它 routing-blind，会泄漏 `:operator_only`。
