# Loom-Stitch → Socialware / Ezagent 迁移分析

> 日期：2026-06-16 ｜ 分析分支：`refactor/loom-stitch-socialware-migration`（切自 `origin/loom-stitch @ 7f7115e9`）
>
> **范围**：本文件**只**基于 `loom-stitch` 分支的功能，不涉及 `feat/loom`。
> loom-stitch 是更新的 loom 形态（per-session 可配置 worker、素材库、Dashboard、
> Stitch 多 worker 重构、token/cost 埋点）。
>
> **权威依据**：
> - 设计权威：`docs/superpowers/specs/2026-06-07-socialware-design.md`（rev8，在 main）
> - 迁移处置框架：`.claude/skills/loom-guide/references/migration-map.md`（提炼版，基于 06-08 的 loom；
>   loom-stitch 06-12~15 的新功能不在其中，本文补判）
> - 数据归宿：`.claude/skills/loom-guide/references/persistence-map.md`
> - 项目债：`.claude/skills/loom-guide/references/pitfalls.md`
>
> ⚠️ **定调（rev8 锁死，不可违反）**：rewrite directly，复用 `main`，**不要 base 在 loom 分支上**。
> loom 变成 socialware 基座上的 **vertical plugin**，只保留独有填充物（page 渲染器 + 编排 prompt +
> page-SDK + 素材库），其余改用 main 基础设施。逐项处置前先
> `git log origin/main -- apps/ezagent_domain_socialware` 核对现状。

> 📐 **方向消歧（避免两处"rewrite"用词撞车造成误读）**：
> 1. 上面定调说的 **"rewrite directly"**，宾语是 **loom plugin 代码**——指「在 `ezagent_plugin_loom`
>    **绿地新写** vertical，不要 fork 旧 loom 分支来改」。B0 说的 **"这是对接不是 rewrite"**，宾语是
>    **main / 架构**——指「不重新设计 main，只对接现成能力」。两个 rewrite 对象不同，不矛盾。
> 2. 本文基于 **loom-stitch 分支**逐功能盘点（附录 A），是把 loom-stitch 当**「要迁哪些功能」的需求来源**，
>    **不是当代码基底**。最终产物 = `ezagent_plugin_loom` 里**绿地新写**、调 main 现成能力的一套 vertical
>    代码 + loom 独有功能自实现；**不 fork loom 实现**，与「不要 base 在 loom 分支」一致。

> 🛑 **权威源滞后警告（2026-06-16 核实，必读）**：本文两个权威依据（migration-map 06-08 +
> design spec rev8）**都早于 main 那轮 Session/Chat 大重构**，B1/B2/B3 的部分映射目标已变或不存在。
> 使用本文前，**必须对 main HEAD 做一次事实重校**。已核实的 main 现状（commit 实证）：
>
> | main 变更 | 对本文的影响 |
> |---|---|
> | `#741` Chat behavior → Session（no back-compat），**`ezagent_domain_chat` 已删除** | 文中所有 `Behavior.Chat` / "from chat domain" 引用**已失效** |
> | `#742/#743/#744` 两个 Session Kind 合并成**一个 parameterized union Kind**（`:kind_base`）+ 删 SocialwareSession Kind | saved classes / fork / roster 应改为「声明 loom 的 `:kind_base` subset + template-content seed」，对齐 `ezagent_domain_session/entity/session.ex` |
> | `#775` `ezagent_domain_instance_message` → **`ezagent_domain_session`**（Turn/Surface 在此） | 红线 #4 边界须含此 domain（见下，已修） |
> | `#727/#728/#736` customer feed = `:pull` ExternalAdapter + **`SocialwarePublisherRead`（scoped, cap-exempt 受控读）** | 红线 #1/#5「禁裸 Publisher」须调和为「禁**未受控**读，受控读走 `customer_feed.ex` / `SocialwarePublisherRead`」 |
> | `#747/#795/#802` anon external-user identity **已落地**（anon_binding/anon_user/public_view） | B7「customer identity anon vs seeded 待 Allen」已被 main 既成事实推翻——main 走 anon |
>
> 下面 B1/B2/B3 的落点已按**对接框架**重校、坐实到 **B0 清单 A** 的 main 现成对接点
> （**无架构改动**——这是对接不是 rewrite）；main 无对应的 vertical 独有功能集中在 **B0 清单 B**。

---

# 第一部分 · Loom-Stitch 完整功能清单

## 角色体系（每 session 一支固定团队）

| 角色 | URI | 职责 |
|---|---|---|
| orchestrator | `loomorch_<sid>` | 每轮：拆解 → fan-out → 聚合 → 组 scene-card；orchestrator instruction 可配置 |
| 业务 worker ×N（**可配置**） | `loomworker_<sid>_<key>` | 主题内容片段；roster 由 `worker_config` 决定（key/desc/prompt），取代旧固定 policy/company |
| v0worker | `loomv0_<sid>` | in-session AI **页面**生成（JSX）；cwd = 该 session 素材目录，放开 Read/Glob/LS |
| meta agent | `loommeta_<sid>` | 团队管家：@自然语言动态改 team |
| **Stitch orchestrator** | `loomstitch_<sid>` | preview 侧 AI：route → fan-out → collect → compose（同编排范式，直连 DeepSeek 快平面）|
| **Stitch sub-worker ×4** | `loomstitchsub_<sid>_<role>` | role ∈ chat / navigation / controls / content；@-only，单次 DeepSeek，回 `stitch_part` |

共同契约：mention-gated（默认只投被 @ 的 agent + User）、ref_id 回执、零 spawn-time 配置注入。
loom Behavior 全部用旧 `use Ezagent.Behavior` 引擎（不是 Lifecycle）。

## 功能分组（41 条路由全归类：40 API 端点 + 1 条 SPA 兜底）

### A. 多 Agent 编排（聊天侧）
| 功能 | 模块 / 端点 |
|---|---|
| 拆解 → fan-out → 聚合 → scene-card | `loom_orchestrator.ex`（`loomorch_<sid>`） |
| **可配置业务 worker**（key/desc/prompt，reconcile 活团队） | `worker_config.ex`、`GET/POST/DELETE /api/:ws/:sid/workers` |
| **可配置 orchestrator instruction** | `GET/POST /api/:ws/:sid/orchestrator` |
| 团队管家（@自然语言改 team） | `loom_meta_agent.ex` |
| 团队幂等装配 | `team.ex` `Team.ensure_team/2`、`template/loom_session.ex` |
| mention-gated 路由 + ref_id 回执 + dead-worker 兜底 | orchestrator + worker |

### B. AI 页面生成（页面侧）
| 功能 | 模块 / 端点 |
|---|---|
| in-session 页面生成（JSX，Sandpack 渲染） | `loom_v0_worker.ex`（`loomv0_<sid>`） |
| 流式生成进度 | `loom:gen_progress` PubSub → SSE |
| 停止生成 | `POST /api/:ws/:sid/stop` |
| **素材库 cwd**（v0 直接 Read 任意素材，不受 prompt 预算限） | `materials.ex`（v0 cwd = 素材目录） |

### C. 发布页 preview 侧 AI（Stitch 体系）
| 功能 | 模块 / 端点 |
|---|---|
| Stitch 聊天（orchestrator + 4 sub-worker 的 route→fanout→compose） | `loom_stitch_worker.ex`、`loom_stitch_sub_worker.ex`、`stitch_experts.ex`、`GET/POST /api/:ws/:sid/stitch` |
| AiSpot ✨ 卡片（单次 DeepSeek，无 fan-out） | `POST /api/:ws/:sid/aispot`（`stitch.mode = "aispot"`） |
| **Stitch 模式开关（human-handoff）** | `worker_config.ex`、`GET/POST /api/:ws/:sid/stitch-mode` |
| 意图推荐"为你推荐"（session-less DeepSeek） | `POST /intent` |

### D. 模板 / 发布 / 分享 / fork（消费侧）
| 功能 | 模块 / 端点 |
|---|---|
| 存为模板（动态 saved class `session.<name>`） | `saved_classes.ex`、`POST /save-as-template` |
| 模板列表 / 删除 / 实例化 | `GET /templates`、`DELETE /templates/:name`、`POST /templates/:name/spawn` |
| 已发布列表（全局 + per-session） | `GET /published`、`GET /api/:ws/:sid/published` |
| 发布（不可变 Class `pub_<hex>` + 冻结快照 + self-heal） | `snapshots.ex`、`POST /publish` |
| 分享快照（16-hex token，只读，带 stitch_config） | `POST /snapshot` → `GET /snapshot/:token` |
| fork 两阶段 | `POST /p/:token/open` + `POST /p/:token/fork` |
| 消费会话标记（创建点打标，隐藏编辑 tab） | `consumer_session.ex` |

### E. 素材库（loom-stitch 特有，「目录即库」）
| 功能 | 模块 / 端点 |
|---|---|
| 上传文件/文件夹（保留目录结构，文件系统即库，无元数据 JSON） | `materials.ex`、`POST /api/:ws/:sid/materials/upload` |
| 列表 / 删除 | `GET/DELETE /api/:ws/:sid/materials` |
| 公开服务图片素材（页面 `<img src="/loom/materials/...">`） | `GET /materials/:ws/:sid/*path`、`GET /uploads/:name` |

### F. Dashboard + 统计（loom-stitch 特有，operator 侧）
| 功能 | 模块 |
|---|---|
| per-session 统计：token / 成本 / 调用时间线 / 按角色（claude_code result 埋点） | `stats.ex`（`loom_stats.json`） |
| 运营控制台（KPI / token 明细 / 角色 / 时间线 / 团队 / 素材 / 知识 / 分享链接） | `loom_dashboard_view.ex`（SessionView，仅创作型 session） |
| 编辑器 iframe SessionView | `loom_session_view.ex` |

### G. 知识库 / 用户体系
| 功能 | 模块 / 端点 |
|---|---|
| 知识库 Markdown（Stitch/AiSpot grounding，随模板发布 + fork 复制） | `knowledge.ex`、`GET/POST /api/:ws/:sid/knowledge` |
| 用户 schema（自定义字段，增强操作序列） | `user_schema.ex`、`GET/POST /api/:ws/:sid/user-schema` |
| 临时用户 / 自助注册 | `temp_user.ex` |
| 身份查询 | `GET /whoami` |

### H. 传输 / 会话
| 功能 | 端点 |
|---|---|
| 发消息 / 历史 / 实时流 / 停止 | `POST .../messages`、`GET .../history`、`GET .../stream`(SSE)、`POST .../stop` |
| 上传 / 资源 / 抓取代理 / 工具 | `POST .../upload`、`GET .../resource`、`POST .../fetch`、`POST .../tool` |
| SPA fallback + vendored 前端 | `GET /*_path` → `priv/static/loom_ui`（Next.js 静态导出） |

### I. 运行时基础设施（loom 自带轮子）
| 功能 | 模块 |
|---|---|
| LLM 壳 + 后端开关（`LOOM_LLM_BACKEND`，默认 claude_code） | `llm.ex` / `claude_code.ex` / `deepseek.ex` |
| 飞书镜像（直插 BindingRow） | `feishu.ex` |
| 编排/页面/Stitch prompt 领域知识 | `prompts.ex` |
| span → scene-card 渲染 | `span.ex` / `stitch.ex` |
| 工具注册 + 内置工具 | `tool.ex` / `tool_registry.ex` / `tools/echo`,`now` |
| bootstrap + plugin 启动（含 httpc 代理） | `bootstrap.ex` / `application.ex` |

## 持久化（loom-stitch 的旁路存储）

| 存储 | 内容 | 模块 |
|---|---|---|
| `loom_workers.json` | per-session worker roster | `worker_config.ex` |
| `loom_orchestrator.json` | per-session 可配置 orchestrator instruction | `worker_config.ex:75` |
| `loom_stitch_mode.json` | Stitch 模式（`stitch`｜`human`，human-handoff 开关） | `worker_config.ex:120` |
| `loom_stats.json` | per-session token/成本/调用统计 | `stats.ex` |
| `loom_materials/<ws>/<sid>/`（**目录即库**，无 JSON） | 上传素材文件树 | `materials.ex` |
| `loom_saved_classes.json` | saved class / 发布 class | `saved_classes.ex` |
| `loom_snapshots.json` | share snapshot（16-hex token） | `snapshots.ex` |
| `loom_knowledge.json` | 知识库 Markdown | `knowledge.ex` |
| `loom_user_schemas.json` | 用户增强操作序列 | `user_schema.ex` |
| `loom_stitch_chats.json`（legacy） | 仅剩 fork 回填快照对话 | `stitch_chat.ex` |
| `loom_consumer_sessions.json` | 消费会话标记（session uri → true，创建点打标） | `consumer_session.ex` |
| 走正轨 | session 对话 + Stitch 对话 → `MessageStore`；agent/session 状态 → Kind snapshot；用户 → Identity | — |

---

# 第二部分 · 迁移对接方案

## B0. 对接框架（2026-06-16 校正：这是对接，不是 rewrite）

**核心认知**：loom 现在的功能**全是自己造的轮子**，没接 ezagent/socialware 的基础设施。
本任务 = 把每个轮子换成**调 main 现成的对接点**。**没有需要改 main 架构的地方**——
凡是看起来像「架构决策」的（选 `:auto` mode、用哪个 `:kind_base`、素材库形态），
经代码核对都是**用 main 现成机制的配置/参数**，不是改架构。

只有当 main **根本没有**对应能力时，才是「对不上」——那部分是 loom 作为 vertical 的
**独有产品功能**，留在 `ezagent_plugin_loom` 里用 main 原语（Turn / curl flavor / Surface）
自己组装，**同样不碰 main**。

### 🔒 三条硬约束（最高优先级，凌驾全文所有处置）

1. **绝对不改 `ezagent` / `socialware` 代码**——一行都不动。所有迁移工作只发生在
   `ezagent_plugin_loom` 内（新增/改 plugin 文件 + 前端）。任何"给 main 加个入参/补个 filter"
   的方案**一律不采纳**，即使它"更好"。
2. **loom 功能中 main 当前不支持的，单独列出（清单 C）**——不去推动改 main，而是如实标为
   "当前做不了"，由 loom 侧让步处理（用现成机制规避 / 降级 / 砍掉，或等 main 将来自己支持）。
3. **逻辑冲突一律以 `ezagent`/`socialware` 为准**——loom 现有行为若与 main 的契约/不变式
   冲突，**改 loom 顺从 main**，不改 main 迁就 loom。

> 据此，下面分三类：**清单 A** = main 现成、直接对接；**清单 B** = main 没有但 loom 可在
> plugin 内用 main 原语自实现（不碰 main）；**清单 C** = main 当前不支持、且只能靠改 main 才能做
> → 按约束 1 **不做**，loom 让步。早期版本把清单 C 写成"需 main 小幅配合 / 走 Allen"是错的——
> 按你的约束，那条路不存在。

### 清单 A · loom 功能 → main 现成对接点（绝大多数，零架构改动）

> 路径说明：下表为 domain **目录名**简写；实际模块在各 domain 的 `lib/ezagent/...` 命名空间下
> （如 `turn.ex` 真实路径 `apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex`）。

| loom 自造功能 | main 现成对接点（代码实证） |
|---|---|
| 编排循环（decompose→fanout→compose） | `Behavior.Turn`（`ezagent_domain_session/behavior/turn.ex`） |
| 即时应答（loom 现有体验） | Turn `handle_open` **硬编码** `mode: :auto`（`turn.ex:246`→`:customer_visible` 即时）——走 auto 即零改动；human-handoff 用运行时 `turn.claim`→`:copilot`（`:315`）。⚠️ operator-**默认**-gated 当前表达不出，见**清单 C** |
| 业务 worker roster + orchestrator 指令 | `AgentTemplate` content + `:kind_base`（`ezagent_domain_agent/entity/agent_template.ex`） |
| v0 页面生成 + 渲染 | `Behavior.Surface`（`ezagent_domain_session/behavior/surface.ex`）+ `json_render.mjs`（`ezagent_domain_socialware/assets/js`，前端已有） |
| 页面发布 / 快照 / fork | Surface 不可变版本 + `approved` 指针 |
| 前端渲染 SPA（customer 侧 json-render） | **P4 chat-external-spa `:pull`**（#732，`customer_app.js` + `json_render.mjs` 现成）；`page_view.ex` 是 **operator** SessionView，非 customer SPA（别混） |
| 素材库上传 / 服务 | `ezagent_core/uploads.ex` + `uploads/download_token.ex` |
| stats（token/cost） | emit `:telemetry.execute [:ezagent,...]` + `ezagent_web/telemetry.ex` metrics 注册（⚠️ `ezagent_core/telemetry.ex` 已被 #678 删，**无单一模块可接**，散在各 core 模块 inline emit） |
| 飞书镜像（**仅 operator 平面零改动**） | `ezagent_domain_external_mirror`（⚠️ customer-visible 镜像需先补 visibility filter——spec §4.3 自列待做，见**清单 C**） |
| 临时用户 / signup | socialware anon（`anon_binding.ex`/`anon_user.ex`/`public_view.ex`，#747/795/802） |
| prompt / 知识库 grounding | `AgentTemplate` content |
| 存为模板 / saved classes | `SessionTemplate`/`AgentTemplate` + `template.read/write` |
| customer 消息流 | `customer_feed.ex`（`:pull`，visibility-gated，#727/#728）。⚠️ **不是换 endpoint 即可**：前端要从全量 SSE 重写为 **cursor-join + advisory 重读**（`committed_deliveries_since/2`）；且 main 有两个 feed——**CustomerFeed（durable delta cursor）vs ChatFeed（snapshot-refresh，无 cursor）**，loom 的 chat / page 两 pane 各接哪个需明确 |
| claude 调用 | cc-flavor PTY（`ezagent_plugin_cc`，详见 B5.7） |
| DeepSeek 调用 | curl flavor（`ezagent_domain_agent/behavior/curl_agent.ex`） |
| 工具 RPC / fetch 代理（page-SDK） | main 无页面级 RPC 传输（#732 P4 只给 feed SPA）。**清单 B**：loom plugin transport adapter 自建端点，内部用 socialware 身份授权（见 B0「page-SDK adapter」） |

**这些没有一个需要改 main 架构**——把 loom 自造实现换成调用上列模块/契约即可。
B1/B2/B3 的「落点」列，都坐实到本表的对接点。

### 清单 B · loom 功能在 main「对不上」（vertical 独有，保留自实现，仍不碰 main）

main 没有也不该有现成对应；对接时留在 `ezagent_plugin_loom`，用 main 原语自组装：

| loom 独有功能 | 为什么对不上 | 留在 vertical 怎么做 |
|---|---|---|
| **Stitch preview-AI 体系**（loomstitch + 4 sub-worker） | main 无「发布页辅助 AI」概念 | Turn 在 preview 侧起第二实例 + curl flavor 调 DeepSeek |
| **DRIVE/OP 协议**（AI 指令式驱动前端） | Surface 是版本快照，无指令驱动协议 | vertical 自定义 message 协议 + 前端约定 |
| **AiSpot ✨ 卡片** | vertical 特有交互 | 单次 curl flavor 调用 |
| **意图推荐 `/intent`**（session-less 选品+pitch） | 纯 loom 业务逻辑 | vertical 端点 + curl flavor |
| **`user_schema` 页面增强引擎**（最终页=base ⊕ per-visitor op 序列） | ⚠️ **最硬**：Surface 是「单一 approved 版本所有访客共享」，无「每访客叠加个性化 op」层 | vertical 自维护 per-visitor op + 前端叠加；**或首版砍掉（产品决策，你定）** |
| **page-SDK 整套**（`sendMessage`/`onMessage`/`tool`/`pfetch`/`uploadFile`…，`platform` 模块） | loom plugin 自己的 web 入口（`forward "/loom"`）；main 无「页面调服务端」扩展点也不需要 | **loom plugin transport adapter** 提供全部端点（P12/P13），内部用 **socialware 身份(anon)+通道(Turn/customer_feed)+授权**（见 B0「page-SDK adapter」）。tool/fetch 白名单逻辑仍是 loom 自己的 |

> 遗留 test-bot flavor（`Behavior.Loom` :say/:receive + `entity/loom.ex` + flavor `"loom"`）
> **不在此列——是删除项**（附录 A.0），不是「对不上」。

### 清单 C · main 当前不支持的 loom 功能（按约束 1 不改 main → **loom 让步，不做**）

这些 loom 功能要实现**必须改 ezagent/socialware**（加入参 / 补 filter）。按硬约束 1：**不改 main**。
所以它们当前**做不了**——loom 侧的处理是「用现成机制规避 / 降级 / 砍掉」，**绝不去推动改 main**。
将来若 main 自己（substrate roadmap）支持了，loom 再接，但那不在本次对接范围。

| loom 想要的能力 | 为何 main 不支持（代码证据） | loom 让步处理（不碰 main） |
|---|---|---|
| **operator-默认-gated 的 turn**（开 turn 即默认 gated，operator 批准才放 customer） | `turn.open` args 仅 `{trigger, opened_at}`，`mode: :auto` **硬编码**（`turn.ex:246`）→ 直接 `:customer_visible`。开 turn 时**选不了** gated；要支持得改 Turn 开仓契约（= 改 domain，禁止） | **用现成的**：loom 走 `:auto`（即时，= loom 现状体验）；需要人工接管时用运行时 `turn.claim`→`:copilot`（现成）。**放弃"默认 gated"这个形态** |
| **customer-visible 外发镜像**（飞书等把 customer 内容外发，且过滤掉 `:operator_only`） | `ezagent_domain_external_mirror` **无 visibility filter**（grep 0 命中）；spec §4.3 自述 Publisher "must gain optional visibility filter"（main 尚未做） | **降级**：飞书只镜像 **operator 平面**（现成可用）；**放弃 customer-visible 外发**，等 main 将来补 filter |

> 这两项是「loom 想要、但 main 现在给不了，且只能靠改 main 才能给」——按约束 1+2，**列出 + loom 让步**，
> 不变成"推动 main 改"的工单。它们都不阻塞主链路（编排→页面→customer feed）落地。

### 清单 D · loom 行为与 main 契约的冲突点（按约束 3：**一律以 main 为准，改 loom**）

loom 现状有几处与 socialware 的契约/不变式直接冲突。按硬约束 3，**全部改 loom 顺从 main**，不反向迁就：

| 冲突点 | loom 现状 | main 契约（以此为准） | loom 改法 |
|---|---|---|---|
| 可见性 | 发消息即时全量可见（`/stream` 全量 SSE，含 worker 中间片段/debug） | visibility-gated，operator/customer 分离（SW-USE 不变式） | 放弃全量 SSE，走 customer_feed 受控读；中间片段对 customer 不可见 |
| 页面状态 | session-rooted **可变**页面 + 自管 snapshot（`snapshots.ex`） | Surface **不可变**版本 + `approved` 指针，Turn 禁 `{:set,:surface}` | 删 `snapshots.ex`，改 `surface.put_version`/`approve` |
| 编排控制 | **手写**状态机（pending/timer/collect/compose 在 Behavior 内） | `Behavior.Turn`（红线 #2：vertical 不写编排状态机） | 删手写循环，改 Turn action |
| 消息读取 | **裸读** `MessageStore`（3 处）+ 裸 Publisher | 只走 `customer_feed` 受控读（红线 #1） | 全部改受控读 |
| 页面个性化 | `user_schema` per-visitor `base⊕op` 叠加 | Surface 是**单一 approved 版本所有访客共享**，无 per-visitor 层 | 以 main 为准：**首版砍 per-visitor 增强**（除非能在 plugin 前端层叠加且不碰 surface；若 customer SPA 不给注入点则砍） |

> 注：清单 D 与 B4 红线互补——红线说「必须怎样」，清单 D 说「loom 现在不这样、要改成这样」。
> 所有改动都在 `ezagent_plugin_loom` 内完成，不碰 main。

### page-SDK = loom plugin 自己的 transport adapter（不是 socialware 扩展点问题）

> 早期版本把「page-SDK customer 边界」当方向级未决/可能降清单 C——**那是想偏了，已纠正**。

loom plugin 本来就是 web 入口（`forward "/loom", EzagentPluginLoom.WebPlug`），page-SDK 的所有端点
（`/messages`·`/stream`·`/tool`·`/fetch`·`/upload`）**都是 loom plugin 自己提供的**。AI 生成页面
`import 'platform'` → fetch 这些端点。**让 loom plugin 提供这些能力 = ezagent 的设计本意**
（P13 transport / P12 adapter / P14 dispatch），不需要 socialware 给「页面调服务端」扩展点。

所以 page-SDK **整体留清单 B**（loom plugin 提供端点），不降 C。唯一的实现约束是
**端点内部用 socialware 的身份+通道**（这样 customer 边界由 socialware 保证、不绕过，符合硬约束 3）：

| 能力 | loom plugin 提供端点，内部接 socialware 的方式 |
|---|---|
| sendMessage（`/messages`） | 身份用 **socialware anon**（不再 TempUser）→ `dispatch` 进 **Turn** |
| onMessage/getHistory（`/stream`·`/history`） | 读走 **customer_feed**（cursor-join 受控读，不裸读 MessageStore） |
| uploadFile/openResource（`/upload`·`/resource`） | `uploads.ex` + 带 customer 身份授权 |
| tool/pfetch（`/tool`·`/fetch`） | loom plugin **继续自己执行**（白名单逻辑是 loom 的），用 socialware 身份做 cap/visibility 授权 |

> 关键转变只有一处：从「loom 自己发明身份（TempUser）+ 自己判断」改成「用 socialware 身份（anon）
> + socialware 读写通道（Turn/customer_feed）+ socialware 授权」。**能力仍由 loom plugin 提供，
> 但「谁能看/能做什么」由 socialware 裁定**——不碰 main、不绕过边界、符合全部约束。**全文已无方向级未决项。**

## B1. 概念对应（loom-stitch 轮子 → main 基础设施）

> 落点的**具体 main 模块**见 **B0 清单 A**（已逐条对代码坐实）；本表给概念级映射。

| loom-stitch | socialware / main |
|---|---|
| 手写编排循环（decompose→fanout→aggregate→compose），**两套**（业务 orchestrator + Stitch orchestrator） | `Behavior.Turn` 的 `open/dispatch/deliver/compose/settle/cancel`——两套各起一个 Turn 实例 |
| per-session worker roster（`worker_config` + `loom_workers.json`） | `AgentTemplate` 声明 + `template.read/write`（roster 是模板状态，不是旁路 JSON） |
| 可配置 orchestrator instruction | SessionTemplate/AgentTemplate content 的覆盖字段 |
| session-rooted 可变页面 + snapshot/fork | `Behavior.Surface` 的 `:surface` slice（不可变版本 + `approved` 指针）；Turn 只能 dispatch `surface.put_version`/`surface.approve` |
| `<span>{json}</span>` scene-card | json-render UI-tree 节点 `%{type, props, children}` |
| 素材库「目录即库」+ 公开 URL 服务 | **受控 asset store**，URL 经 visibility-gate；v0 的 cwd 访问改受控读 |
| Stitch 模式开关（human-handoff toggle） | socialware **operator takeover** 原生语义（`:operator_only` / operator 介入），删自建 toggle |
| LLM 壳（claude_code/deepseek/llm.ex） | flavor 机制（cc / codex / curl），AgentTemplate 声明 |
| token/cost 统计（`stats.ex` + `loom_stats.json`） | ezagent **telemetry**（`[:ezagent, ...]` events）+ metrics |
| Dashboard SessionView | HEEx `PageView`（operator-only），读 telemetry/metrics |
| 直插 BindingRow 飞书镜像 | `ExternalMirror`（visibility 过滤） |
| `/stream` SSE-from-Publisher | **visibility-gated customer feed**（⚠️ 不复用 SSE） |
| 浏览器临时用户 / signup | customer identity model + session-binding token |
| saved classes（动态 Class） | `Entity.SessionTemplate` / `AgentTemplate` + `template.read/write` |

## B2. 逐功能处置

图例：🗑️ 丢弃 ｜ ♻️ 改写下沉 ｜ 📦 移植 ｜ ⏸️ 后置（vertical 产品范围，**非架构、非 Allen**）

| 功能（第一部分编号组） | 处置 | socialware/ezagent 落点 | phase |
|---|---|---|---|
| A 编排循环 | ♻️ | `Behavior.Turn` action；策略进 orchestrator prompt | P5 |
| A 业务 worker | ♻️ | `turn.deliver(subtask_id, ...)`；worker 定义入 `AgentTemplate` | P5 |
| A 可配置 worker roster（worker_config） | ♻️ | `template.read/write`，**删 `loom_workers.json`** | P5 |
| A 可配置 orchestrator instruction | ♻️ | SessionTemplate/AgentTemplate content 覆盖字段 | P5 |
| A meta agent | ⏸️ | 倾向首版不做，用 Routing + fork 覆盖 | — |
| B v0worker 页面生成 | ♻️ | page-worker；落库由 Turn compose 时 dispatch `surface.put_version` | P5 |
| B 素材库 cwd（v0 读素材） | ♻️ | 受控 asset 读；不直接把 OS 目录设 cwd（plugin 不碰裸 FS 资产） | P5 |
| C Stitch orchestrator + 4 sub-worker | ⏸️/♻️（**清单 B**） | vertical 独有：若保留 → 第二个 `Behavior.Turn` 实例（preview 侧）+ curl flavor，不自建 route/fanout/compose | P5+ |
| C AiSpot 单次调用 | ⏸️/📦 | vertical 增量（单次 flavor 调用） | P5+ |
| C **Stitch 模式开关 / human-handoff** | ♻️ **关键** | 删自建 toggle，改接 socialware **operator takeover**（基座原生，非 vertical 新功能） | P5 |
| C /intent 意图推荐 | 📦 | session-less flavor 调用，归 vertical 增量 | P5+ |
| D saved classes / 模板 | ♻️ | `template.read/write` + SessionTemplate/AgentTemplate | P5 |
| D publish / snapshot | 🗑️（snapshots.ex） | `:surface` 版本天生不可变，无需独立快照 | P5 |
| D fork | ♻️ | 从 SessionTemplate 起新 session | P5 |
| D consumer_session | ♻️ | customer identity model 一部分 | P5 |
| E 素材库 materials | ♻️ | 对接 `ezagent_core/uploads.ex` + `download_token`（现成）；**公开 URL `/materials/...` 经 visibility-gate**（红线 #6），删「目录即库」裸 FS 服务 | P5 |
| F stats（token/cost 埋点） | ♻️ | emit `:telemetry.execute [:ezagent,...]` + `ezagent_web/telemetry.ex` 注册 metrics（⚠️ 无 `ezagent_core/telemetry.ex`，已被 #678 删），**删 `loom_stats.json`**；数据绝不进 customer feed | P5 |
| F Dashboard view | ♻️ | HEEx PageView（operator-only），读 telemetry/metrics | P5 |
| G knowledge | 📦 | 进 AgentTemplate content | P5 |
| G user_schema | 📦 vertical（**清单 B**） | main 无 per-visitor 页面增强层 → vertical 自维护 op 序列；**首版是否保留 = 产品决策（你定，非架构）** | P5+ |
| G 临时用户/signup | ♻️ | customer identity model + session-binding token（→ **anon**，main #747/#795/#802 已定，见头部🛑/B7） | P5 |
| H 传输（messages/history/stream） | ♻️ **不复用 SSE** | Turn + visibility-gated customer feed（query + outbox 事件） | P5 |
| H 前端 SPA + json-render + upload/resource | 📦 | **P4 基座** SPA（#732 `:pull`）+ `uploads.ex`（现成，清单 A） | P4 ✅ |
| H page-SDK **工具 RPC + fetch 代理** | 📦 vertical（**清单 B**） | loom plugin transport adapter 自建端点，内部用 socialware 身份授权（见 B0「page-SDK adapter」） | P5 |
| I LLM 壳 / 飞书 / bootstrap | 🗑️ **全删** | flavor 机制（claude → cc-flavor PTY agent，详见 **B5.7**）/ `ExternalMirror` / 基座启动 | P5 |
| I prompts | 📦 | 进 AgentTemplate content；⚠️ **不能照搬**：loom prompt 按 stateless per-turn 写（每轮全新 claude），迁到常驻 PTY agent（B5.7）后跨轮上下文保持，prompt/隔离假设要重审 | P5 |

## B3. 数据迁移

| loom-stitch 存储 | 迁移指向 |
|---|---|
| `loom_workers.json`（roster） | → `AgentTemplate` + `template.read/write`（🛑stale：对齐统一 Kind 的 `:kind_base` subset） |
| `loom_orchestrator.json`（orchestrator instruction） | → SessionTemplate/AgentTemplate content 覆盖字段（与 worker roster 同处置，别漏迁） |
| `loom_stitch_mode.json`（`stitch`｜`human`） | → socialware operator takeover 状态（注意 main 是 tri-mode `:auto/:copilot/:takeover`，binary 需映射） |
| `loom_stats.json` | → emit `:telemetry.execute [:ezagent,...]` + `ezagent_web/telemetry.ex` metrics（无 `ezagent_core/telemetry.ex`，#678 已删；不落旁路 JSON） |
| `loom_materials/`（目录即库） | → 受控 asset store（visibility-gated 服务） |
| `loom_saved_classes.json` | → `template.read/write` |
| `loom_snapshots.json` | 🗑️ 消失 → `:surface` 不可变版本 + 指针 |
| `loom_knowledge.json` | → AgentTemplate content |
| `loom_user_schemas.json`（页面增强 op，**清单 B**） | → vertical 自维护，或首版砍（产品决策） |
| `loom_stitch_chats.json`(legacy) | 🗑️ |
| `loom_consumer_sessions.json`（消费会话标记） | → customer identity model（消费 vs 创作二分） |
| session 对话 + Stitch 对话（已在 MessageStore） | → visibility-gated customer feed（**废除现有裸读**：`web_plug.ex` 3 处 `MessageStore.recent_in_session`（:637 history / :1209 stitch_conversation / :1494 latest_page_update）+ **`template/loom_session.ex:312`（第 4 处）** + `/stream` SSE，全是红线 #1/#5 要替换的路径）。⚠️ 前端读模型要从全量 SSE **重写为 cursor-join**（CustomerFeed 有 cursor / ChatFeed 用 snapshot-refresh，两 pane 分别接） |
| 临时用户 | → Identity（`entity://<ws>/user/<name>`，URI 段序以当前 SPEC 为准） |

## B4. 迁移红线（违反 = 返工）

1. customer feed **只走 visibility-gated query + outbox 事件**——禁 `MessageStore.recent_in_session` / 裸 Publisher / 未过滤 ExternalMirror（⚠️ ExternalMirror 的 visibility filter main 尚未实现，见**清单 C**）。
2. vertical 里**不写编排状态机**——业务侧与 Stitch 侧都用 `Behavior.Turn`（零 core 代码）。
3. page **不自管 mutable 状态**——`:surface` 不可变版本 + 指针；Turn 禁 `{:set, :surface}`，只能 dispatch surface 动作。
4. **绝对不修改** core / domain（`ezagent_core` / `ezagent_domain_session` / `ezagent_domain_socialware`）——**一行不动**（B0 硬约束 1）；vertical 只**依赖** `ezagent_domain_session`（Turn/Surface）+ `ezagent_domain_socialware`（base 契约：`:surface` / `Message.visibility` / customer feed），**新增文件只进** `ezagent_plugin_loom`。main 给不了的能力 → 清单 C（loom 让步，不推动改 main）。
5. **不复用 `/stream` 的 SSE-from-Publisher**（routing-blind，泄漏 `:operator_only`）；customer feed 读走 main 的**受控**路径（`customer_feed.ex` / `SocialwarePublisherRead`，#727/#728），不是裸 Publisher。
6. **素材公开 URL 不裸服务**——`/materials/...` 资产经 visibility-gate；plugin 不直接把 OS 目录设 v0 cwd（受控读替代）。
7. **stats / Dashboard 是 operator-only**——token/cost 等运营数据绝不经任何路径到达 customer feed。

## B5. loom-stitch 特有功能的迁移要点（migration-map 未覆盖，本文补判）

> 对照提示：migration-map（06-08 loom）记 web_plug "24 条路由"，loom-stitch 已涨到
> **41 条**——新增主要就是下面这几群（materials / workers / orchestrator / stitch-mode /
> intent / per-session published）。对照框架时别把这个数字差当矛盾，是分支快照不同。

这 6 群是 loom-stitch 相对旧 loom 的增量，权威迁移清单（06-08）没写，处置判断如下：

1. **可配置 worker（worker_config）** — 最干净的下沉：roster 本质是模板声明，socialware 用 AgentTemplate + `template.read/write` 表达，**旁路 JSON 整个消失**。
2. **素材库 materials** — 最需要小心：当前是「目录即库 + 裸文件服务 + v0 cwd 直读」，三点都踩 visibility/边界红线。迁移要重写成受控 asset store，公开 URL 过 gate，v0 改受控读。
3. **Stitch 体系（orchestrator + 4 sub-worker）** — 结构上已是第二个编排器，正好映射成第二个 `Behavior.Turn` 实例；但首版倾向后置（辅助聊天非核心 SW-USE）。
4. **Stitch 模式开关（human-handoff）** — 概念上等于 socialware 的 operator takeover，**基座原生能力**，迁移=删自建实现改接基座，不是移植。
5. **stats + Dashboard** — token/cost 埋点改走 ezagent telemetry；Dashboard 是 operator-only HEEx PageView。注意 operator/customer 隔离红线。⚠️ 现状缺口：`stats.ex` 只埋 claude_code plane（v0/orch/worker），**Stitch/DeepSeek plane 未埋点**（Dashboard 已诚实标注）——迁移到 telemetry 时应顺手补齐 DeepSeek plane 的 usage/cost。
6. **per-session published / 多发布物归因** — 随 publish→`:surface` 版本机制一起处理。
7. **LLM 调用机制（`claude -p` → cc-flavor PTY agent）** — 改动最大、最影响行为的一块，
   B2「I LLM 壳 🗑️全删→flavor」那行不足以表达，展开如下（main 现状已核实）：

   | | loom-stitch 现在 | 迁移后（main 机制） |
   |---|---|---|
   | claude 唤起 | **`claude -p` headless one-shot**（`claude_code.ex`：`claude -p <prompt> --output-format json`，erlexec `:exec.run` 读 stream-json，**不用 PTY**） | **local-pty 长驻 claude 进程**：`ezagent_plugin_cc` 的 `cc.agent` Template「spawn path always local-pty」→ 起 `PtyServer`（`Ezagent.Domain.Pty`） |
   | 调用模型 | 每轮 spawn → 出结果即死（**stateless per-turn**） | 长驻进程跨轮保持（**stateful session**） |
   | 通信 | 解析 stdout JSON `.result` | **MCP bridge**（esr-bridge `--mcp-config`，mcp_channel/mcp_server） |
   | 进程管理 | loom 自管：erlexec 异步流式 + 空闲超时 + group 停止（`ezagent_loom_claude_runs` 表） | 归 cc 插件 PtyServer + `orphan_reaper`，loom **不再自管进程** |
   | 隔离 | `--exclude-dynamic-system-prompt-sections` 防串戏 + 跟随本地登录态 | per-agent `CLAUDE_CONFIG_DIR`（cc 插件每 agent copy 一份 config dir） |
   | DeepSeek 侧 | `deepseek.ex` 直连（Stitch/AiSpot/intent） | **`flavor: curl`/deepseek，不走 PTY**（普通 HTTP） |

   要点：**claude 侧 worker/orchestrator/v0 → 声明 `flavor: cc` 的 AgentTemplate，由 cc 插件 PTY 承载**（不是 loom 直接调 PtyServer）；
   **DeepSeek 侧不走 PTY**。所以「全部用 PTY」不准确，是分平面的。
   行为差异：one-shot→常驻意味着上下文跨轮保持（loom 现在每轮全新 claude），prompt 设计与隔离假设都要重审。

   ⚠️ **缝隙隐患（清单 A 两行的交点）**：v0 现在靠 `claude -p` 的 cwd=素材目录 + 放开 Read/Glob/LS
   **直读**素材；迁到 cc-flavor PTY 后工具走 MCP bridge，素材访问要改成受控读 `uploads.ex`。
   「claude→PTY」与「素材→uploads」分列两行，但**「PTY agent 如何受控读 uploads 素材」这个交点未验证**，
   是被三分法切散、落在缝里的实施假设——动手前要先验通。

## B6. 落点 phase

| 内容 | phase | main 状态 |
|---|---|---|
| page-SDK + fetch_proxy + tool + span→json-render + 前端 SPA | **P4** 基座 | ✅ 已落地（#732，走 `:pull` 路线，先读再动） |
| behavior/template/entity/prompts/worker_config/materials/stats/Dashboard/Stitch → 瘦身 `ezagent_plugin_loom` | **P5** 第一个 fused vertical + SW-USE E2E | 前置 config-evolve（#733）已动 |

## B7. 决策点（无架构决策；仅产品范围 + 既成事实）

> 早期版本这里列了 4 条「待 Allen 架构决策」——**已撤回**，经代码核对它们全是「用 main 现成机制」
> 或「vertical 产品范围」，不触发架构 grill（见 B0）。

**已定（main 既成事实，按现状对接，无需决策）**：
- customer identity → **anon external-user**（#747/#795/#802 已落地）。
- 即时应答 → Turn `mode: :auto`（**硬编码默认**，走 auto 零改动；human-handoff → 运行时 `turn.claim`→`:copilot`）。⚠️ operator-默认-gated 见**清单 C**。
- 素材库 → `ezagent_core/uploads.ex`（现成，不新建 asset Kind）。
- worker roster / orchestrator 指令 → `AgentTemplate` content + `:kind_base`（现成机制）。

**仅需你（产品）拿主意的范围选择（非架构）**：
- 清单 B 各 vertical 独有功能首版是否纳入：`user_schema` 页面增强（最硬，建议首版砍）、
  Stitch preview-AI 体系、AiSpot、`/intent`、meta_agent。
- 这些都不阻塞主链路（编排→页面→customer feed）落地，可后置增量。

## B8. 首版完成判据（设计 §9 SW-USE 不变式）

一个 settled turn 同时驱动 customer 两个 pane（chat 气泡 + 实时 page）；operator 批准前
customer 看不到任何东西；`:operator_only` 内容绝不到达 customer feed。

---

# 附录 A · 逐模块完整清单与处置（51 个 .ex，无遗漏）

> 前面正文（A1–I / B1–B8）按「功能组」归纳，会吞掉藏在实现里的功能。本附录**逐源文件**
> 列全，标 **🆕** = 之前正文吞掉或低估、本轮深读才补上的功能/约束。处置图例同 B2
> （🗑️丢弃 ｜ ♻️改写下沉 ｜ 📦移植 ｜ ⏸️后置）。

## A.0 关键结构澄清：loom 里并存两套

| 套 | 组成 | 性质 | 迁移 |
|---|---|---|---|
| **🆕 遗留 test-bot flavor 套** | `entity/loom.ex`（Kind）+ `behavior/loom.ex`（:say/:receive）+ `template/loom_agent.ex`（pure-spawn flavor class）+ flavor `"loom"` + default instance `loom_agent` | fixed-reply 测试 bot（"你好！我是测试机器人！"）+ v0.1 DeepSeek web brain + 飞书 fan-out 入口；是 plugin 契约骨架 | 🗑️ **整套删**（test bot 无业务价值；flavor 声明的"形"由 socialware 真实 cc/curl flavor 取代） |
| **实际 session 编排套** | loomorch / loomworker / loomv0 / loommeta / loomstitch(+sub) + team + worker_config + 全部 session-rooted 服务 | 迁移主体 | 见下表逐条 |

> ⚠️ 之前正文（含 B1/B2）把 `behavior/loom.ex` / `entity/loom.ex` / `loom_agent` / flavor `"loom"`
> **完全没提**——它们不是编排链路的一部分，但占着 plugin 声明、是删除项，迁移时要识别清楚别误留。

## A.1 Behavior 层（7）

| 模块 | 真实职责（🆕=新补） | 处置 |
|---|---|---|
| `behavior/loom.ex` | 🆕 v0.1 DeepSeek web brain：`:say`（scene-card 脑）+ `:receive`（飞书/session 友好 fan-out），可镜像 session+飞书 | 🗑️ |
| `behavior/loom_orchestrator.ex` | 编排核心：decompose→fan_out→收集→compose；🆕 `:agg_timeout` 定时器兜底、🆕 用户可配 orchestrator 指令注入 decompose/compose | ♻️ `Behavior.Turn` |
| `behavior/loom_worker.ex` | 业务 worker；🆕 loop-guard（仅 @ 自己才动）、🆕 §11 Gate 3 用 `Router` 不用 `Invocation` | ♻️ `turn.deliver` |
| `behavior/loom_v0_worker.ex` | 页面生成 worker：出 page_update span；🆕 cwd=素材目录直读 | ♻️ page-worker + `surface.put_version` |
| `behavior/loom_meta_agent.ex` | 团队管家：@自然语言→DeepSeek→spawn/terminate+join/leave；🆕 副作用=底层原语组合，无新 action/caps | ⏸️（Routing+fork 覆盖） |
| `behavior/loom_stitch_worker.ex` | Stitch orchestrator：route→fan-out→compose；🆕 `stitch`/`aispot` 双模式、🆕 stitch_debug trace | ⏸️/♻️ 第二 Turn 实例 |
| `behavior/loom_stitch_sub_worker.ex` | Stitch 4 sub-worker（chat/nav/controls/content）；@-only，回 `stitch_part` | ⏸️/♻️ |

## A.2 Entity 层（7，薄 Kind 声明）

| 模块 | 职责 | 处置 |
|---|---|---|
| `entity/loom.ex` | 🆕 遗留 test-bot Kind（canned reply，echo-clone 减 PTY）；⚠️ 现 supervisor 引 `EzagentDomainInstanceMessage.AgentSupervisor`——**该 domain 已改名 `ezagent_domain_session`（#775，见头部🛑）** | 🗑️ |
| `entity/loom_{orchestrator,worker,v0_worker,meta_agent,stitch_worker,stitch_sub_worker}.ex` | per-角色 Kind 声明 | ♻️ 统一 Session/Agent Kind + `:kind_base`，**独立 Kind 不再需要**（#743） |

## A.3 Template 层（8）

| 模块 | 真实职责（🆕=新补） | 处置 |
|---|---|---|
| `template/loom_session.ex` | 🆕 装配核心 SessionTemplate：instantiate→spawn 裸 Session+`Team.ensure_team`；🆕 save-as-template 把 `:loom_source` 页面快照进模板；🆕 触发 gap（UI 用户消息要 @orchestrator，per-session routing rule deferred）；⚠️ moduledoc 同 stale（仍写 `ensure_team/1` + 2 workers，与 `team.ex` 一类） | ♻️ SessionTemplate + `:kind_base` subset |
| `template/loom_agent.ex` | 🆕 遗留 pure-spawn flavor class（仅为满足 flavor 声明+gate） | 🗑️ |
| `template/loom_{orchestrator,worker,v0_worker,meta_agent,stitch_worker,stitch_sub_worker}.ex` | per-角色 Kind template | ♻️ AgentTemplate seed |

## A.4 服务 / 逻辑模块（含被吞掉的功能）

| 模块 | 真实职责（🆕=新补） | 处置 |
|---|---|---|
| `team.ex` | 团队装配 reconciler；⚠️ moduledoc **stale**（仍写固定 policy/company，实际已被 worker_config 驱动）；⚠️ 满引 `EzagentDomainInstanceMessage`——**已改名 `ezagent_domain_session`（#775）** | ♻️ template-driven 装配 |
| `worker_config.ex` | per-session 可配 worker roster（key/desc/prompt）+ stitch_mode | ♻️ AgentTemplate + `template.read/write` |
| `materials.ex` | 素材库「目录即库」+ v0 cwd 直读 + 🆕 公开 URL 裸 FS 服务 | ♻️ **受控 asset store**（踩红线 #1/#4/#6，必重写） |
| `stats.ex` | per-session token/cost 埋点；🆕 仅 claude_code plane，DeepSeek 未埋 | ♻️ telemetry（补 DeepSeek plane） |
| `saved_classes.ex` | 存为模板：🆕 runtime `Module.create/3` 动态编译 Class；🆕 契约违规更深——直接 `:ets.delete` 注册表 + `:code.purge/delete`（无 deregister API，pitfalls #5） | ♻️ `template.read/write`（顺带消违规） |
| `snapshots.ex` | share snapshot；🆕 fork **不重放历史**（前端只读展示，避免 re-dispatch 违反 P14） | 🗑️ `:surface` 不可变版本 |
| `knowledge.ex` | 知识库 Markdown（Stitch/AiSpot grounding，随发布+fork 带走） | 📦 AgentTemplate content |
| `user_schema.ex` | 🆕 **per-visitor 页面增强引擎**：最终页=base ⊕ op 序列（非"自定义字段"） | ⏸️ |
| `consumer_session.ex` | 🆕 创作会话 vs 发布消费会话二分（创建点打标，决定是否显示编辑 tab） | ♻️ customer identity model |
| `stitch.ex` | 🆕 Stitch 共享逻辑：能力驱动 prompt + **DRIVE:/OP: 协议**（驱动页面/增强操作）+ grounding | ⏸️/♻️（保留 DRIVE/OP 协议） |
| `stitch_chat.ex` | legacy 对话存储（仅剩 fork 回填） | 🗑️ |
| `stitch_experts.ex` | Stitch roster/prompts/parsers（transport-agnostic） | ⏸️/♻️ |
| `span.ex` | 🆕 scene-card 规范化护栏：**组件选择是纯函数非 LLM**（PRD 护栏 #9） | ♻️ json-render（**保持纯函数性质**） |
| `prompts.ex` | 领域知识单一真相源（scene-card 系统提示+persona，634 LOC） | 📦 AgentTemplate content |
| `temp_user.ex` | per-visitor 临时 User Kind；🆕 隔离不在此（在 ws_token 层）、🆕 reclaim 未接线 | ♻️ anon external-user（#747/795） |
| `feishu.ex` | 🆕 **直写 `BindingRow` 绕过 cap-checked `ExternalMirror.bind`**（system/temp caller 无飞书身份） | ♻️ `ExternalMirror`（须解决 caller identity） |
| `bootstrap.ex` | 🆕 per-visitor 装配（create session+temp user+team+feishu+join）；🆕 HTTP 前端已退役，现为 `mix run`/e2e 脚本入口 | 🗑️/测试夹具 |
| `llm.ex` | LLM 后端分发（boot 开关 `LOOM_LLM_BACKEND`）+ stop/max_run_ms 桥接 | 🗑️ flavor 机制 |
| `claude_code.ex` | 🆕 `claude -p` one-shot（erlexec 异步流式+空闲超时+group stop，详见 **B5.7**） | 🗑️ cc-flavor PTY agent |
| `deepseek.ex` | DeepSeek HTTP 壳（`:httpc`，非流式） | 🗑️ curl flavor |
| `fetch_proxy.ex` | 🆕 AI 页面白名单 HTTP 代理（`:fetch_presets` 正则+方法白名单安全过滤） | 📦 P4 page-SDK |
| `tool.ex` / `tool_registry.ex` | 🆕 白名单服务端工具 RPC（`platform.tool`）+ ETS registry + **prompt_block 把工具+args_schema 暴露给 AI** | 📦 P4 |
| `tools/echo.ex` / `tools/now.ex` | 内置工具（echo smoke-test / 服务端可信时间） | 📦 P4 |

## A.5 Web / View / Application（4）

| 模块 | 真实职责（🆕=新补） | 处置 |
|---|---|---|
| `web_plug.ex`（1586 LOC） | 41 路由入口；🆕 send_to_session 默认 @orchestrator、🆕 3 处裸读 MessageStore（:637/:1209/:1494）、🆕 /stream 全量 SSE | ♻️ 拆：page-SDK→P4、消息链路→Turn+customer feed |
| `view/loom_session_view.ex` | 编辑器 iframe SessionView（仅创作会话） | ♻️ HEEx PageView |
| `view/loom_dashboard_view.ex` | operator Dashboard（KPI/token/角色/时间线/团队/素材/知识/分享链接） | ♻️ operator-only PageView |
| `application.ex` | 🆕 plugin 契约声明：`behaviors`/`template_classes`/`agent_flavors`("loom")/`config_surface`/`after_boot`(default instance)/🆕 httpc proxy 配置(dev Clash)/🆕 SessionView 注册 | ♻️ 重写为瘦身 vertical 声明（删 test-bot flavor、httpc proxy 随 deepseek 删） |

## A.6 之前正文遗漏 / 低估项汇总（本轮新增）

1. **遗留 test-bot flavor 整套**（A.0）——之前完全没提，是 🗑️ 删除项。
2. **`behavior/loom.ex` 的飞书 bot 入口**（:say/:receive）——独立于 session 编排的第二入口。
3. **`user_schema.ex` = per-visitor 页面增强引擎**——之前误述为"自定义字段"。
4. **`fetch_proxy` / `tool` 的白名单安全机制**——page-SDK 的安全维度，迁移到 P4 要保留白名单语义。
5. **`span.ex` 确定性组件化护栏**（纯函数非 LLM）——迁移到 json-render 必须保持。
6. **`stitch.ex` DRIVE/OP 协议**——Stitch 回复驱动页面/增强操作的协议。
7. **`feishu.ex` 绕 cap check 直写 BindingRow**——迁移 ExternalMirror 时的 caller identity 障碍。
8. **`snapshots.ex` fork 不重放历史**（P14 约束）。
9. **`saved_classes.ex` runtime `Module.create` + 契约违规**——动态编译 Class，pitfalls #5。
10. **LLM 调用机制 `claude -p`→PTY**（已在 B5.7 展开）。
11. **`team.ex` moduledoc stale** / `bootstrap.ex` 已退役 / `application.ex` 的 httpc proxy + SessionView 注册等运维细节。

**运行时设施收口（非模块，但属"完整清单"）**：
- **ETS 表 ×2**：`tool_registry` 的 `@table`（工具查找）+ `claude_code.ex` 的 `ezagent_loom_claude_runs`（在跑 claude 进程，group 停止用）→ 迁移随各自模块处置消失。
- **PubSub topic**：`loom:gen_progress`（v0 页面生成进度 → SSE）→ ♻️ customer feed / surface 版本事件。
- **env vars**：`LOOM_LLM_BACKEND` / `DEEPSEEK_KEY` / `FEISHU_MIRROR_ENABLED` / `FEISHU_SYNC_CHAT_ID` / `EZAGENT_PROFILE`（+ `HTTP(S)_PROXY`）→ flavor/ExternalMirror 接管后多数消失。
- **无 mix task**（`mix/tasks` 为空）；test 在 `test/`（8+ `_test.exs`，无 fixtures 目录）。
