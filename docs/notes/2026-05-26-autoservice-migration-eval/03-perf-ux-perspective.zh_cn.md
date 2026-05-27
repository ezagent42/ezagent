# 会话性能与体验迁移评估（subagent 3：perf/UX 视角）

> 评估范围：AutoService Pipeline V2 在会话流程性能 / 感知延迟 / 用户体验上的优化能否、怎么迁移到 ezagent。**用户最关心的维度**。
>
> 立场：假设要迁，给具体映射方案 + P0/P1/P2 优先级。

---

## 0. ezagent 现状基线（quick grep 结果）

ezagent 当前是 router + Kind/Behavior dispatch 框架，已落地：

- **ReadyGate**（`apps/ezagent_core/lib/ezagent/ready_gate.ex`）— ETS 3 态，`:unknown/:not_ready/:ready`，`:cast` → PendingDelivery，`:call` → fail-fast
- **PendingDelivery**（`apps/ezagent_core/lib/ezagent/pending_delivery.ex`）— ETS bounded buffer，per-URI 100 slot，flush 时按到达顺序排出
- **Idempotency**（`apps/ezagent_core/lib/ezagent/idempotency.ex`）— v0 语义"收到即记"
- **Notifications**（`apps/ezagent_core/lib/ezagent/notifications.ex`）— 统一 user-inbox 出口，cap-gated（`:notify` cap），向 `esr:user:<uri>:events` 广播 — **这是合法的 outbound 路径**
- **ExternalMirror Domain**（`apps/ezagent_domain_external_mirror/`）— Adapter pattern + Publisher 订阅，`target_ownership_check/2` 是 Adapter 唯一允许的 I/O callback
- **Publisher Behavior**（`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/publisher.ex`）— cursor + retention=100 events 的 typed event stream，订阅者拿 `{:publisher_event, %Event{}}`
- **cc 子进程**：`ezagent_plugin_cc.Template.CcAgent` 模式是 local-pty + WebSocket bridge（`/cc_socket` → `cc:bridge:<agent_uri>` topic）；spawn 时 SDK system_prompt 烧死
- **Telemetry** 已普遍接入

**缺什么（grep 已确认零命中）**：

- `prewarm` / `warmup` 概念 — 无（cc 子进程是 lazy spawn）
- 快路径并发回复（DeepSeek / Haiku ack 等） — 无
- FillerLoop / 进度填充 — 无
- KB prefetch — 无（实际整体无 KB 概念）
- Model tier 升级（`set_model` 等价） — 无（一个 Agent 一个 spawn-time 模型）
- Side-channel 剥离 / preamble 剥离 — 无
- per-turn 结构化 perf 日志（`[v2-perf]` 风格） — telemetry 在但无统一 turn 维度

下面 12 项逐项展开。每项标注 **P0/P1/P2** 优先级。

---

## 1. fast/cc 双相位编排（P0）

**AutoService 实现要点**：`pipeline_v2/orchestrator.py:135-184` `handle_message` 按 `state.phase ∈ {fast, cc}` 路由。`fast_phase` 当 prewarm 未完时直接把 DeepSeek 一次 HTTP 输出作为本轮终回复（`orchestrator.py:187-277`）；`cc_phase` 当 prewarm 完成时跑 cc + 并发 DeepSeek + FillerLoop（`orchestrator.py:343+`）。熔断阈值 `_FAILURE_THRESHOLD = 3`（line 44），`state.permanently_v1` 永久回退。

**UX 问题**：首轮（冷启动）客户等不起 cc 的 3-8s spawn + 8s LLM。fast 相位让首轮 1-2s 内出可用回复。

**迁移方案**：放在 **domain** 层。在 `ezagent_domain_chat` 加一个 `Ezagent.Domain.Chat.SessionOrchestrator` GenServer per session（或扩 `cc_orchestrator_seed.ex`），状态机 `:cold | :warm`。Behavior 加 `Ezagent.Behavior.Chat.FastReply`，由 `Ezagent.Behavior.Chat` 在 `handle_action(:receive, ...)` 内部判断状态后 dispatch — **关键：仍走 dispatch 而非直接调用**。

**不变式风险**：低。orchestrator 是 Session Kind 内部 state，对外行为不变。fast 相位调外部 DeepSeek API 等价于 ExternalMirror 出 + reply 入，可放进现有 `Ezagent.Behavior.Chat` 的内部逻辑或独立 Behavior。

---

## 2. 并发 DeepSeek 抢 ack（P0）

**AutoService 实现要点**：`orchestrator.py:423-429` `asyncio.create_task(_fire_deepseek_ack_concurrent(...))`。`_SKIP_ACK_INTENTS = {"greeting", "escalation"}`（line 62）：cc 自己出短回复时跳过。短输入 length-skip `_ack_skip`（`zh<8 / en<15`，line 406）整体关掉 ack+filler。目标 1.2s 内出第一帧 topic-anchored 回复，与 cc 并行不阻塞 cc TTFT。

**UX 问题**：cc 思考期空白屏 = 客户怀疑系统挂了。topic-anchored ack（"我帮您查退款资料"）比 cc 出现前的 8s 静默体验差 10 倍。

**迁移方案**：放在 **domain/chat**。新 Behavior `Ezagent.Behavior.Chat.FastAck`（或附在 SessionOrchestrator 内部）。实现：dispatch `:cc_query` 时同步 spawn 一个 `Task.Supervisor.async_nolink` 跑 fast LLM 调用，结果通过 `Ezagent.Notifications.notify/2` 推 user inbox（`{:notification, ..., %{type: :fast_ack, body: %{text: ...}}}`）— 这是合法 outbound。`Task` 在 cc finish/timeout 时取消。

**不变式风险**：**P14（dispatch is the only path）冲突点**。Task 不是 Kind，但它的输出不进 dispatch — 它通过 `Notifications.notify` 走"events out-bound"，这是 P14 明确允许的 — outbound 用 PubSub OK，inbound 才禁。**关键防御**：Task 必须 link 到 SessionOrchestrator 的 Task.Supervisor 而非裸 spawn，避免 orphan。

---

## 3. FillerLoop（P0）

**AutoService 实现要点**：`pipeline_v2/fast_agent/filler_loop.py` 整文件 132 行。`_JITTER_LO=0.8`/`_JITTER_HI=1.2`（每 5s±20%），`_FILLER_TEXTS_ZH` 10 条静态备份（line 21-32），`text_provider` 可注入 DeepSeek 动态生成（line 109-115，失败回退静态库），`max_count=3`，去重防"同一句两连发"（line 122-126）。`metadata.is_filler=true` 让 operator UI 可折叠。

**UX 问题**：cc 多步 tool loop 可能 17-19s（doc §4.5），中间 5-15s 完全无字。filler 不是"承诺"（"还在为您处理"而非"我帮您查了"）— 失信防御写在 CLAUDE.md filler rule。

**迁移方案**：放在 **domain/chat**。Elixir 等价物简单：在 SessionOrchestrator 内 `Process.send_after(self(), :tick_filler, jittered_interval)`，handle_info 内 dispatch 一个 `:emit_filler` 给 self 或直接走 `Notifications.notify`。**关键：不要 spawn 一个独立 GenServer 跑 FillerLoop** — 用 SessionOrchestrator 自带的 schedule，停止时无需 Process.exit。

填充语 metadata 上加 `is_filler: true`，沿用 ezagent Notifications 的 `:body` map 自由形。

**不变式风险**：**P14 兼容点 1**。filler 的"emit"必须不走 dispatch 到自己 — 直接进 ExternalMirror Publisher 的 event stream（标记 `kind: :filler`），或经 Notifications。**绝对不能**新增一个 `:filler_inbound` topic 让别的 Kind 订阅 — 那是事故 2.1 形态。

---

## 4. cc_pool prewarm on page open（P0）

**AutoService 实现要点**：`runner.prewarm`（runner.py 上面）调 `pool.acquire_sticky(sticky_key, tenant_id=sticky_tenant)` + `pool.checkin(instance)`（runner.py:99-101）。fire-and-forget，failure 只打 warning。SSE 路径已接入（`routes.py:218`，doc §5），WS deferred。把 cc subprocess 冷启动（spawn + claude SDK init + soul 注入）成本前移到页面加载这个用户已经在等的时刻。

**UX 问题**：cc spawn 冷启动 2-5s，首条消息延迟翻倍。

**迁移方案**：放在 **domain/chat** 或 **plugin/cc**。LiveView 挂载时（或 chat session URI 创建时）dispatch 一个 `:prewarm` action 到 cc agent URI — `Ezagent.Behavior.Cc.Prewarm`。dispatch 会触发 SpawnRegistry.spawn → CcAgent template instantiate → PtyServer 启动（cc_agent.ex line 20-34 的 instantiate 流程已经做了"BOTH ensures Agent Kind exists AND starts PtyServer"）。

**不变式风险**：**低**，但要注意 P14：prewarm 的 `:prewarm` action 走真实 dispatch 即可，不需要 PubSub trick。SpawnRegistry.spawn 已是 dispatchable 路径。

---

## 5. Sticky cc instance with tier upgrade（P1，长期成本节流）

**AutoService 实现要点**：`cc_pool.py:2559+ _maybe_upgrade_tier`：spawn 时跑 haiku-4-5（便宜+快+预热），运行时检测到 `tier="slow"` 调 `instance.client.set_model(slow_model)`（line 2581）切到 sonnet-4-6。subprocess 不重启，conversation context 保留。doc 给出日志线索 `sticky tier upgraded to slow: conv=... model=claude-sonnet-4-6`。

**UX 问题**：成本/体验 trade-off — 预热便宜模型省钱，复杂回复升级到强模型保质量。

**迁移方案**：**plugin/cc**。Claude SDK 是否暴露 `set_model` 决定能不能做。如果 PtyServer 跑的是 stdin/stdout 协议而不是 SDK，需要重新建立 PTY 上下文 — 那这优化代价 > 收益。建议先存档为 **P2**，等 cc agent 的 SDK 抽象稳定。

**不变式风险**：跨层泄漏 risk。如果 Behavior 直接调 `instance.client.set_model`，违反 P12 / P13（plugin 不能直接调底层）。要走 dispatch `:set_model` action 给 cc agent Kind，Kind 内部做实际切换。

---

## 6. KB MCP prefetch 模式（P1）

**AutoService 实现要点**：`runner.py:168-169` `cfg.kb_mode == "mcp_with_prefetch"` → 调 `_try_kb_prefetch(tenant_id, customer_text)` → `queries.search(top_k=10)`（`pipeline_v2/kb_mcp/queries.py:295`）→ 注入 `<kb_context>` 块到 prompt。cc 不再调 KB tool，tool_calls=2-4 → 0，**延迟 17-19s → 5-9s**（doc §4.5）。

**UX 问题**：KB-heavy tenant 每次 tool loop 都 round-trip = 体感卡。

**迁移方案**：ezagent 当前无 KB Domain。如果未来加 KB，应在 **domain** 层（`ezagent_domain_kb`）。Behavior `Ezagent.Behavior.Kb.Search`。prefetch 实现：SessionOrchestrator 在 dispatch `:cc_query` 前先 dispatch `:kb.search` 拿 top-k 结果，作为 `args` 中的 `prefetched_kb` 字段给 cc agent。cc agent 收到后注入 prompt。

**不变式风险**：低。两个 dispatch 串接是合法链路。注意 `:kb.search` 必须是 cap-gated action（caller 持 `:read` cap on KB URI）。

---

## 7. Skill 热重载 vs Soul 重启（P2，运维）

**AutoService 实现要点**：skill 是 `.read_text()` per query 无缓存（doc §4.2 蓝色 💡），git pull 即生效。soul 是 spawn-time 烧死的 SDK `system_prompt`，必须 `make stop && make start`。区分对运维迭代速度的影响。

**UX 问题**：迭代闭环秒级 vs 分钟级 — 是 agent 设计师生产力的核心。

**迁移方案**：在 ezagent 里 cc agent 的 system_prompt（soul-equivalent）当前来自 Template Class 的 `template_data`，instantiate 时烧死。要做热重载需：（a）skill 拆出来作为 cc agent 启动时挂载的"运行时可读路径"，cc 通过 MCP tool 或 prompt-template re-render 每次 query 重读；或（b）把 skill 内容存进 ezagent 的 Resource/Entity，每次 dispatch `:cc_query` 重新构造 prompt。

**架构建议**：在 ezagent 里 soul 应该是 cc agent 的 `template_data` 的一部分（一次性，重启生效），skill 应该是 user-scoped Resource URI，dispatch 时 enrich 进 args。

**不变式风险**：低 — 是个 domain modeling 决策。

---

## 8. Side-channel + preamble 剥离（P0 — 数据正确性级）

**AutoService 实现要点**：

- `_SideChannelStrippingSink`（`autoservice/integrations/general_bot/reply_pipeline.py`）— 把 cc 回复尾部的 `[线索] ...` SIDE 块从客户视图剥掉转给 operator。strict + flexible 双 schema 防御。
- `parse_customer_preamble`（`autoservice/preamble_stripper.py`）— `_SHORT_LEAD_PREAMBLE` regex bank 剥 "请稍等，查询一下…" 类客户端不该看的 preamble（zh + en 都覆盖）。

**UX 问题**：cc 在客户视图出现 `[线索] 联系方式: ...` 这种系统内部 marker = 严重的 trust loss + PII 泄漏。同样 "请稍等…" 当前面已经有 ack 之后又出现一次会让客户读出"卡了/重复了"。

**迁移方案**：放在 **domain/chat**（不是 plugin — adapter 不应该懂业务 marker）。新 Behavior `Ezagent.Behavior.Chat.OutputFilter` 作为 cc agent 出口的 wrapper。或者用 ezagent 已有的 Publisher.Event 的 transform pipeline：cc agent emit `%Event{kind: :assistant_reply, body: raw_text}`，注册 Domain-level filter 把 raw_text 分裂为 `customer_text` + `side_text`，分别 Notifications.notify 到 customer 和 operator。

AutoService 给出的契约文档参考：`docs/contracts/lead-summary-wire-format.md` + CI lint `tests/lead_summary/test_wire_format_lint.py` — ezagent 应该一开始就上 CI lint 防止 soul/skill 内嵌 wire 模板（已经有这文化）。

**不变式风险**：低。整个过滤链都在 outbound 方向，符合 P14。**唯一警告**：filter 是 stateless 纯函数比照 ExternalMirror Adapter 的 `event_to_payload/1`，不要在里面 dispatch（再次违反"adapter 不能再入"原则）。

---

## 9. Transcript token-limit 截断 + previous_session 格式化（P2）

**AutoService 实现要点**：`PIPELINE_V2_TRANSCRIPT_TOKEN_LIMIT=1500`（doc §4.2 表），格式化为 `<previous_session>` 块。

**UX 问题**：transcript 无限增长 → 长会话 token 爆 → 延迟+成本+幻觉。

**迁移方案**：在 **domain/chat** 的 SessionOrchestrator 构 prompt 时做。ezagent Session Entity 已经持有消息历史，加一个 `Ezagent.Domain.Chat.TranscriptCompactor` 模块（pure function），输入 messages + token_budget，输出截断后的 transcript text。

**不变式风险**：无。纯函数 helper。

---

## 10. DeepSeek 失败诊断观测性（P1）

**AutoService 实现要点**：`reason=` 字段在 `_generate_deepseek_filler_text` 的 `except (DeepseekError, TriageParseError) as e: logger.warning("v2 deepseek filler/ack failed reason=%s text=%.30s", e, ...)`（orchestrator.py:793-796）。`[v2-perf]` 结构化日志含 `deepseek_call_count` / `t_filler_count` / `t_phase` / `t_pushed - t_deepseek_start`。`perf["deepseek_ack_skipped"]` 字段标 skip 原因（length/greeting/escalation）。

**UX 问题**：不是直接 UX，但**没有 perf 日志 = 无法回归分析体验衰减**。

**迁移方案**：在 **core**。利用 ezagent 现有 `Ezagent.Telemetry`，加 `[:ezagent, :session, :turn, :stop]` event，measurements 包含 `t_phase_ms / t_fast_ack_ms / t_cc_first_byte_ms / t_cc_complete_ms / filler_count / fast_skipped_reason`。比 AutoService 的 logger.info 字符串更结构化 — 直接对接 Prometheus/Grafana。

**不变式风险**：无。telemetry 是 outbound，符合 P14。

---

## 11. 熔断到 V1（permanently_v1）（P1）

**AutoService 实现要点**：`state.deepseek_failures >= 3 → state.permanently_v1=True`（orchestrator.py:242-243）。重启清空状态。

**UX 问题**：避免每条消息都卡 3s 等 DeepSeek timeout → 整个对话变难用。

**迁移方案**：在 SessionOrchestrator state 内加一个 `:fast_ack_disabled?` flag + 失败计数。三次失败后只走 cc。**关键设计**：ezagent 的 Kind state 默认是持久化的（snapshot-on-change，P22）— 这个 flag 重启后不应该自动清，可能需要显式存进 transient 字段 + 加个 admin "reset" action。

**不变式风险**：P22（reliability primitives in core）— 不要在 Behavior 里写自己的熔断逻辑，应该有 `Ezagent.CircuitBreaker` core primitive。如果还没有，是个独立 PR 候选。

---

## 12. Transcript snapshot + 短消息合并 + 短输入 skip（P1）

**AutoService 实现要点**：

- `state.transcript.snapshot()`（orchestrator.py:362）拿快照避免并发修改 race
- `_ack_skip` length 阈值（zh<8 / en<15）整体关 ack+filler 防止 3 个 bubble 堆叠（详见 cc_phase 内部注释 lines 382-405 — 有详细 live incident 复盘 cust_869f30c7）
- **voice 例外**（line 399-405）：voice 走 audio 没 bubble 概念，length-skip 反而产生 3-7s 死寂 → voice 始终发 ack

**UX 问题**：边界条件下旧行为产 3 个 AI 气泡 = 客户读出"系统坏了"。

**迁移方案**：domain/chat 的 SessionOrchestrator 内加 input classification helper：`Ezagent.Domain.Chat.InputClassifier.short?/1` + 按 channel 类型（text vs voice）查表。channel 信息在 ezagent 里通过 ExternalMirror Adapter 的 binding 知道。

**不变式风险**：低。注意 channel 类型不能跨 dispatch 传 — 应该在 invocation `ctx` 里加 `channel_kind` 字段（已有 trace_id / deadline_ms 等惯例字段）。

---

## 13. 综合落地优先级建议

**必须先迁（P0 — 直接客户感知）**：

1. **fast/cc 双相位编排（§1）** — 没这个，prewarm 也没用，cc 冷启动直接砸客户脸
2. **并发 fast ack（§2）** — 1.2s 内出第一帧是 UX 底线
3. **FillerLoop（§3）** — cc tool loop 期间不能空白屏
4. **cc prewarm（§4）** — 跟 §1 是配对的，必须同时上
5. **Side-channel + preamble 剥离（§8）** — 安全 / 信任 / PII 红线，不剥是事故

**可以稍后（P1 — 成本/质量 trade-off）**：

6. KB prefetch（§6）— 等 KB Domain 上线
7. 观测性 + perf telemetry（§10）— 上 P0 同时一起做
8. 熔断 V1 fallback（§11）— P0 上线后 1 周内补
9. 短消息 / channel-aware skip（§12）— UX 调优，第一版可不做

**可暂缓（P2 — 运维 / 长期成本）**：

10. Skill 热重载（§7）
11. Tier upgrade（§5）
12. Transcript 截断（§9）

---

## 14. 关键陷阱 / dispatch-only-path 兼容性（P14 守护）

**核心问题**：FillerLoop + Concurrent ack 都要"从一个内部进程定时推消息到客户的消息流"，看起来像广播。怎么不违反"dispatch is the only path between Kinds"？

**答案**：**P14 管的是 inbound**，outbound 的 customer-facing notification 走 `Ezagent.Notifications.notify/2`（cap-gated PubSub broadcast 到 `esr:user:<uri>:events`）或 ExternalMirror Publisher event stream。这两条都是 ezagent 已经定义并 CI 守护的合法 outbound 路径，不是绕过 dispatch。

**具体落地建议**：

| AutoService 概念 | ezagent 等价路径 | 走 dispatch? |
|---|---|---|
| fast_ack 推 customer | `Notifications.notify(user_uri, %{type: :fast_ack, body: %{text: ...}})` | 否（outbound） |
| FillerLoop tick | SessionOrchestrator `handle_info(:tick_filler)` → `Notifications.notify` | 否（outbound） |
| cc 正式回复 | cc agent emit `%Publisher.Event{kind: :assistant_reply}` → ExternalMirror Worker → Notifications | 否（outbound chain） |
| customer 入 inbound | adapter → `Invocation.dispatch(%Invocation{target: session_uri, mode: :cast, args: %{text: ...}})` | **是**（这是唯一 inbound 路径） |
| cc spawn / prewarm | `Invocation.dispatch(%Invocation{target: agent_uri, mode: :call, args: %{action: :prewarm}})` | **是** |

**最容易踩雷的地方**：FillerLoop 想"广播 filler 给 session 让 session 重新 dispatch 给客户" — 这是 inbound 路径，**违反 P14**。正确做法是 SessionOrchestrator 自己拿 customer's user_uri，直接 `Notifications.notify` 出 — 不要绕一圈让 filler 表现成"一条入站消息"。

**第二个雷**：并发 fast_ack 的 `Task` 不要 link 到 SessionOrchestrator 主进程 — 一旦 fast LLM 抛异常，主 Kind 也死。用 `Task.Supervisor.async_nolink/3` + monitor，符合 P22 的"reliability primitives"哲学。

**第三个雷**：tier upgrade（§5）如果做 — Behavior 直接 `instance.client.set_model(...)` 跨层违反 P12 / P13。必须 dispatch 一个 `:set_model` action 到 cc agent，由 cc agent Kind 内部完成 — 这又会和"set_model 必须保留 conversation context"的 SDK API 限制冲突，技术 feasibility 待验证。

---

## 关键源码引用清单（绝对路径）

AutoService 端：

- `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\2026-05-07-pipeline-v2-session-flow.md`（主文档）
- `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\autoservice-overview.md` §6
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\orchestrator.py:44`（`_FAILURE_THRESHOLD=3`）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\orchestrator.py:62`（`_SKIP_ACK_INTENTS`）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\orchestrator.py:343-500`（`_cc_phase` 并发编排）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\orchestrator.py:848-870`（`_fire_deepseek_ack_concurrent`）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\fast_agent\filler_loop.py:21-132`（FillerLoop 全文）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\main_agent\runner.py:99-101`（prewarm `acquire_sticky`）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\main_agent\runner.py:168-174`（kb prefetch hook）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\cc_pool.py:2559-2585`（`_maybe_upgrade_tier`）
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\preamble_stripper.py`（preamble strip）

ezagent 端（迁移目标 / 已有基础设施）：

- `D:\Work\h2os.cloud\ezagent\apps\ezagent_core\lib\ezagent\ready_gate.ex`
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_core\lib\ezagent\pending_delivery.ex`
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_core\lib\ezagent\notifications.ex`（合法 outbound — 关键）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_core\lib\ezagent\invocation.ex`（dispatch 入口）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_domain_external_mirror\lib\ezagent\behavior\publisher.ex`（typed event stream，cursor）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_domain_chat\lib\ezagent\orchestrator\cc_orchestrator_seed.ex`（SessionOrchestrator 落点候选）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_plugin_cc\lib\ezagent\template\cc_agent.ex`（cc 子进程 Template 落点）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_plugin_cc\lib\ezagent\plugin_cc\socket.ex`（cc bridge socket）
