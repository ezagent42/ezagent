# 基础架构迁移评估（subagent 1：infra 视角）

> 评估范围：基础架构 / 运行时 / 进程模型。不评估业务逻辑或 UI。
>
> 立场：假设要迁，给具体映射方案。

---

## 1. cc_pool → ezagent 进程模型映射

**AutoService 现状**：`cc_pool.py:1868 class CCPool(AsyncPool[CCClient])` 是单进程 Python 中一个全局可变 dict（`_sticky_bindings`, `_eval_sticky`, `_upgraded_sticky`），按 `key=(chat_id|conv_id)` sticky 复用 ClaudeSDKClient subprocess；`acquire_sticky` (`cc_pool.py:2241`) 同时承载：(a) sticky 复用，(b) per-tenant quota (`StickyTenantQuotaExceeded`)，(c) tenant 不匹配拒绝 (`StickyTenantMismatch`)，(d) `_recycle_instance_for_tenant` 烧 soul，(e) `_pool_session_id` 防 disk-session resume，(f) `_maybe_upgrade_tier` 调 `ClaudeSDKClient.set_model` 原地升级 haiku→sonnet (`cc_pool.py:2559`)。

**ezagent 现状**：cc plugin 一个 `entity://agent/<workspace>/cc_<name>` 对应 **一个** `Ezagent.Entity.Agent` Kind 进程 + 一个 PtyServer sidecar（`apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex:262 instantiate/3`）。没有"池"概念——Template Class 的 instantiate 是 1:1 (agent_uri→pty)，且 PTY 跑 `claude` CLI 而非 `claude_agent_sdk` 进程。

**Gap + 建议**：

- **池→Kind 集合**：cc_pool 的"(tenant, role)→list of subprocesses"在 ezagent 不应实现为新池抽象（会违反 **P8 少发明多装配** + **P22 reliability primitives live in core**）。正确映射是：每个 (workspace, role) 对应 N 个 `entity://agent/<workspace>/<role>_<idx>` Agent Kind，由 **Workspace Loader 在 boot 时通过 SessionTemplate.agent_slots 声明性预声明**（`Ezagent.Workspace.Loader.load_all/0` 已是 cc plugin `after_boot/0` 的钩子，见 application.ex:116）。
- **sticky binding → Session ↔ Agent 绑定**：sticky `key=conv_id` 等价于 `session://<template>/<workspace>/<conv_id>`，绑定到 agent 走 `Ezagent.WorkspaceRegistry.bind/2`（P17）+ SessionTemplate.agent_slots 的 routing rule。**chat_id→agent 的归属由 Session Kind 持有**，不是池外的 dict。
- **set_model 原地升级**：cc plugin 的 PtyServer 启 `claude` CLI 没有等价 `set_model` 控制消息（cc CLI 自身不支持 mid-conversation 切 model）。这是结构性 gap，不要假装能做：升级语义在 ezagent 应是 **dispatch `agent.swap_model` action** → 触发 Agent Kind terminate + `Ezagent.SpawnRegistry.spawn_detailed/1` 重建 PtyServer with new claude args（**会丢 conversation context**——cc CLI 当前没有 in-place context handoff）。建议先做 Decision Log 新条目：`mid-session model swap deferred — claude CLI lacks in-place model control message`。
- **per-tenant quota**：cc_pool 的 `max_sticky_per_tenant`（cc_pool.py:447）映射到 `workspace_uri NOT NULL`（不变式 #14）+ workspace 内 routing rule cap 限制活跃 agent 数量。不需要新 quota 抽象。
- **PoolableClient.is_healthy + max_lifetime_seconds + max_queries_per_instance** → 这正是 **P22 ReadyGate + PendingDelivery** 的应用场景。lifetime 回收应放进 `Ezagent.Entity.Agent` 的 slice（`max_invocations: int, spawned_at: timestamp`），到期由 Agent Kind 自己 dispatch `agent.recycle` action，**不是池在外面 reap**。

---

## 2. 入站 → 编排 → 后端 fan-out 重写

AutoService 三入站 (`/ws/customer`, `/chat/{tid}` SSE, `/ws/voice`) → `pipeline_v2.orchestrator.handle_message`（`orchestrator.py:135`）→ `_fast_phase` (deepseek) | `_cc_phase` (cc_pool.session_query + FillerLoop) → `cc_pool` / `deepseek HTTP` / `KB MCP`。

**映射**：

| AutoService | ezagent |
|---|---|
| `/ws/customer` WebSocket | `ezagent_web` Phoenix.Channel adapter → `Ezagent.Invocation.dispatch/1` 进 `session://default/<ws>/<conv>?action=chat.send`（**P12 adapter**） |
| `/chat/{tid}` SSE | 同上，另一个 adapter |
| `/ws/voice` | 新 plugin (`ezagent_plugin_voice`)：voice ASR/TTS bytes 走外部 SFU（**brainstorm trade-off：媒体流不进 dispatch**，见 anti-patterns "Let's abstract a generic 'channel'…"）；只有 ASR-final 文本进 `Chat.send` |
| `pipeline_v2.orchestrator` _SessionState | **Session Kind 的 slice**（`Ezagent.MessageStore` + session slice 自定义字段 `phase`, `permanently_v1`, `deepseek_failures`） |
| `_fast_phase` (deepseek HTTP) | 新 Behavior `Ezagent.Behavior.FastAck`，由 Session Kind 上的 orchestrator 派发到一个 deepseek-flavor Agent (`entity://agent/<ws>/deepseek_fast`)。**注意 P14**：不要在 Session 的 `handle_info` 里直接发 HTTP；通过 dispatch 到一个 Agent Kind，Agent 持有 HTTP client |
| `_cc_phase` (cc_pool.session_query) | 已经有 `Ezagent.Behavior.Chat.invoke(:send, ...)` 走 routing → cc Agent Kind → PtyServer (`cc_agent.ex`) |
| `KB MCP server` (cc 内 tool call) | cc plugin 已经在 cc `--mcp-config` 里塞 bridge MCP；新增 KB tool 是 plugin 内 MCP server，**不变**——P12 adapter 内部，不暴露到 dispatch 表面 |
| `FillerLoop` (周期发安抚) | Session Kind 用 `Process.send_after/3` self-tick → dispatch `chat.send` with `source: :filler`（**不要 PubSub.broadcast**，否则违反 P14） |
| `failures counter + permanently_v1` | Session slice 字段 + **snapshot-on-change**（P22），不要全局 ETS |

**fan-out 路径自查**："这条 message 如果没人接收，谁会知道？"——AutoService 现在没人知道（orchestrator return 一个 str 就完事）；ezagent 强制 `Ezagent.Routing.Resolver.resolve/4` 零匹配→ DLQ-unroutable + telemetry（P22），**自动获得**。

---

## 3. 多租户隔离：能契合的 / 会冲突的

**天然契合**：

- AutoService `tenant_id` 直接映射 ezagent `workspace`。`.autoservice/data/tenants/<tid>/...` → `workspace://<tid>` + 派生 URI `entity://agent/<tid>/cc_customer`、`session://default/<tid>/<conv>`、`resource://soul/<tid>/customer.md`、`resource://kb/<tid>/kb.db`。3-段权威（不变式 #11）正好放得下。
- `_sticky_bindings` 按 tenant 区分 → `WorkspaceRegistry.bind/2`（不变式 #4）+ workspace_uri 提取 O(1)（P17）。
- KB sqlite (`.autoservice/data/tenants/<tid>/kb/kb.db`) → `resource://kb/<tid>/main` 的 slice 元数据指向物理文件（per-tenant DB 表 schema 仍需 `workspace_uri NOT NULL` 不变式 #14；KB 内容本身在外部 sqlite，slice 只存 pointer + 元数据）。

**会冲突的**：

- **cross-workspace fan-out**：cc_pool warmup 把多 tenant 的 instance 预 spawn 在**同一 BEAM**——这没问题；但任何"common pool 临时让 tenant A 的 instance 服务 tenant B"是**结构性 deny**（不变式 #13 `:cross_workspace_denied`）。AutoService 的 `StickyTenantMismatch` 抛错正好对齐这条不变式——可以直接对接。
- **`/_master` sentinel**：cc_pool.py:639 `_MASTER_TENANT_FOR_SOUL = "_master"` 作为 platform/global soul 的虚拟 tenant。映射到 `workspace://system`（不变式 #13 "system 是 cross-workspace 结构性 sink"）。**注意 P11**：master soul 不是 plugin 独立 scheme，应是 `resource://soul/system/<role>`。
- **L0-L3 soul 4 层合成**：AutoService 在 `_load_soul`（cc_pool.py:1118）每次拼装 4 个文件。映射到 ezagent：4 层 soul = `resource://soul/<scope>/<role>` 的 4 个独立 Kind 实例（L0=`workspace://system`，L1=`workspace://platform-<industry>`，L2=`workspace://industry-<ind>`，L3=`workspace://<tid>`），由 cc Agent Kind 在 spawn 时 dispatch `resource.read` 读 4 份再拼装。这里**不要发明 "soul layer resolver"**（违反 P8）——4 次 dispatch + 一个纯函数 join 就够。
- **不入 git 的租户数据 vs SQL 表**：AutoService 的 `.autoservice/data/tenants/<tid>/` 是文件树；ezagent 现状是 SQLite 表。不变式 #14 要求 `workspace_uri NOT NULL`——AutoService 的 channel overlay YAML / section YAML 全部要进 `kind_snapshots`（多路复用）或自己开表 + workspace_uri 列。**地域驻留（EU / China）的多 Repo 分库**是 ezagent 当前 SPEC 未覆盖的，是迁移期必须开 Decision Log 新条目的真问题。

---

## 4. 状态机 / 熔断 / prewarm 用 OTP 重写

| AutoService state | OTP 重写 |
|---|---|
| `_SessionState.phase: "fast" \| "cc"` (orchestrator.py:67) | Session Kind slice 字段 `phase`；状态切换由 `chat.send` Behavior 的 `handle_call` 持有，snapshot-on-change（P22） |
| `_SessionState.deepseek_failures` + `permanently_v1` 熔断 | Session slice `deepseek_failure_count` 字段；超阈值 → dispatch `session.set_permanent_v1` action 到自己（**P14**：自 Kind action 仍然走 dispatch，不直接改 state）；同时 emit `:start/:stop/:exception` telemetry（P19 #3）让运维看到熔断 |
| `_STATES: dict[str, _SessionState]` 全局 dict | **删除**——ezagent `KindRegistry` 就是 `session_uri → pid` 的权威 SoT（P3），Session Kind 进程本身持有 state，崩了由 supervisor + snapshot 恢复 |
| `_upgraded_sticky: set` (cc_pool.py 模块级) | 直接进 Agent Kind slice `upgraded?: boolean`；snapshot-on-change |
| `state.lock: asyncio.Lock`（per-conv 串行化） | OTP 天然按进程串行（Session Kind 的 mailbox），**不需要 lock**——这是 P8 "少发明多装配"的最大收益 |
| `_query_lock: asyncio.Lock`（CCClient 内 query+receive_response 串行，cc_pool.py:137） | PtyServer 自身就是 GenServer 串行；**已无对应物**，免费拿到 |
| `cc-dot artifact` race（cc_pool.py:130-136 注释） | OTP 模型下这个 race 根本不存在 |

**prewarm**：

AutoService prewarm 是 web 页面 fire-and-forget `acquire_sticky` 提前 spawn（典型 trigger 在前端 onload → `/api/prewarm/<tid>`）。**在 ezagent 这事**怎么做：

- **不是 P14 违反**——prewarm 是"提前把 Kind 启起来"，不是消息发送。`Ezagent.SpawnRegistry.spawn_detailed/1` 本来就是声明性的非消息接口。
- **首选方案：声明性 prewarm，不要 hook**。把 prewarm 配置进 SessionTemplate / WorkspaceLoader：workspace boot 时 `agent_slots: [%{role: :cc_customer, prewarm: 3}]` 触发 `Workspace.Loader.load_all/0` spawn 3 个 idle agent。这天然契合 cc plugin `after_boot/0` 已有的 `Workspace.Loader.load_all()` 调用（application.ex:118）。
- **次选：HTTP 端点 → dispatch `workspace.ensure_warm`**。新增 `Workspace` Kind 的 Behavior action `:ensure_warm`（target 在 `workspace://<tid>`，scope-owning Kind 是 workspace 本身，P11 + 不变式 #12 完美对齐），由 web adapter 接 `/api/prewarm/<tid>` → dispatch。**不要做 Session lifecycle hook**——hook 是隐式控制流，违反"每条消息谁会知道"。
- **Voice prewarm（"reply with '.'" primer，cc_pool.py:132）就不要做了**——那是 cc_pool 单池架构的 workaround；ezagent 一个 conv 一个 Session Kind + 各自的 cc Agent Kind 进程，没有跨 conv 串扰，这个 hack 自然失效。

---

## 5. 风险与不变式冲突清单

| 不变式 / 原则 | 迁移期会撞到的红线 | 来源代码 |
|---|---|---|
| **#1 / P14** dispatch is the only path | AutoService orchestrator 直接 `await deepseek_client.complete(...)` + `await cc_pool.session_query(...)`——这两个调用在 ezagent 必须改成 `Ezagent.Invocation.dispatch/1`，不能在 Session Kind 的 handle_call 里裸调 HTTP。 | `orchestrator.py:135` |
| **#7 / P18** dispatch mode is transport choice | 入站 ws/customer 必须用 `:call` 模式 + 反向 reaction，**不能 silent drop**（AutoService 现在 fast_phase 失败默默降级为 static fallback，没有反馈给客户失败原因；ezagent 红线） | `orchestrator.py:187 _fast_phase` |
| **#11** 6-scheme allowlist | 不要造 `feishu://` / `cc-pool://` / `voice://` / `kb://`——新通道走 Behavior on Session/User Kind | n/a |
| **#13** cross-workspace dispatch deny | `cc_pool._STATES` 多 tenant 共享全局 dict 必须拆 → 每个 workspace 独立 KindRegistry segment | `cc_pool.py:80 _STATES` |
| **#14** per-tenant DB `workspace_uri NOT NULL` | AutoService kb_chunks / sections / overlays / chunks 的 SQLite/YAML schema 全部要补这列；CR 表（draft / release）也是 | `.autoservice/data/tenants/<tid>/...` |
| **#15** ExternalMirror Domain for outbound | 如果之后要把 cc agent reply 反向 mirror 出 Feishu/Slack——必须走 ExternalMirror Adapter+Binding，**不能**复制 cc_pool 内部直接发送的代码路径 | n/a |
| **P22** reliability primitives in core | 不要新造 `Pool` 抽象在 plugin 层；ReadyGate / PendingDelivery / Idempotency 已经覆盖 cc_pool 的 health-check + queue 语义 | `cc_pool.py:145 is_healthy` |
| **P25** channel meta = Record<string,string> | KB MCP 工具调用回 cc 的 `notifications/claude/channel` 必须 stringify；AutoService 现在没有这个约束 | `apps/ezagent_domain_chat/test/.../chat_test.exs` |
| **anti-pattern "deterministic orchestrator"** | 不要为了"控制流明确"把 fast/cc/filler 编排重写成 Elixir 状态机硬代码；orchestrator 应该是 LLM-driven Behavior（Decision D7-1）+ scope-bounded caps，**保留** AutoService 让 deepseek 做 triage 的设计 | anti-patterns.md `"Make orchestrator deterministic"` |

---

## 6. 推荐落地顺序（4 phase）

**Phase A — Workspace + Soul Resource 基础设施**

- 新 plugin `ezagent_plugin_autoservice_soul`：4 层 soul 作为 `resource://soul/<scope>/<role>`；SoulLoader 是 pure function，从 4 个 Kind dispatch 拉数据后 join。
- WorkspaceLoader 扩展：从 `.autoservice/data/tenants/<tid>/` 声明性映射出 workspace。
- 验收：`mix ezagent.demo.seed_autoservice_workspace tid=demo` 起一个 workspace，dispatch `resource://soul/demo/customer?action=read` 返回 4 层 join 结果。

**Phase B — cc Agent + Session orchestrator MVP（单 tenant，single channel）**

- 复用现有 cc plugin；为 deepseek 新增 plugin `ezagent_plugin_deepseek`：一个 deepseek-flavor agent kind，Behavior `Chat.send` 调 HTTP。
- 新 Behavior `Ezagent.Behavior.OrchestratorPipelineV2` 注册在 Session Kind 上，持有 fast/cc phase + 失败 counter 的 slice 字段。
- 入站：`ezagent_web` 加 `/chat/<workspace>/<conv>` SSE adapter（P12 纯 adapter，业务全在 dispatch 后）。
- 验收：单 tenant 全链路 e2e，fast_phase + cc_phase + FillerLoop 三条流跑通；invariant test `no_silent_drop_at_orchestrator_test.exs` 通过。

**Phase C — 多租户 + workspace_uri DB 改造**

- 给 Session/Agent/MessageStore 加 `workspace_uri NOT NULL` 列 + index。
- `cross_workspace_isolation_test.exs` + `workspace_isolation_test.exs` 全绿。
- Voice plugin：仅文本路径走 dispatch；ASR/TTS 字节流由独立 SFU 处理（**不**用 dispatch 传媒体）。

**Phase D — Prewarm + 模型升级 + CR/sandbox/release**

- Workspace Behavior `:ensure_warm` 替代 AutoService web onload prewarm。
- 模型升级先做 "terminate + respawn"（接受丢上下文），同时记 Decision Log；in-place set_model 等 cc CLI 支持后再做。
- CR/sandbox/release 映射到 SessionTemplate fork（**仅配置**，不带 history，不变式 #10）+ Workspace pointer flip。

---

## 关键评估文件路径

- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\cc_pool.py:1868,2241,2559,3622,3827`（CCPool 主体 + sticky + 升级 + tenant instance）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\orchestrator.py:65-184`（_SessionState + handle_message）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\cc_pool.py:1118-1202`（_load_soul 4 层合成）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_plugin_cc\lib\ezagent\template\cc_agent.ex:262-358`（instantiate + spawn_for_local_pty）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_plugin_cc\lib\ezagent\plugin_cc\application.ex:88-120`（plugin contract + after_boot 钩子）
- `D:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\architecture-invariants.md`（17 条不变式，特别 #1 #4 #11 #13 #14 #15）
- `D:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\design-principles.md`（P14 P17 P22 P25）
- `D:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\anti-patterns.md`（"deterministic orchestrator"、"PubSub.broadcast 跨 plugin"、"generic channel for media"）
