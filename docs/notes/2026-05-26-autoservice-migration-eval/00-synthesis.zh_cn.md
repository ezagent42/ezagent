# AutoService → ezagent 综合迁移评估（4 视角合成）

> 4 个 subagent 并发评估的合成报告。原始视角见同目录 01-04 子文件。

---

## 0. 一句话结论

**ezagent 全迁不推荐；推荐"混合方案 + 优先吸收会话流程优化"**：把 ezagent 当 identity / workspace / routing / audit 底座，AutoService Python 主体（cc_pool / Pipeline v2 / voice / admin portal）保留；但 **AutoService 在 Pipeline v2 里沉淀的 12 项会话流程优化必须迁到 ezagent 的 chat domain**——这是用户感知最强、不迁会输的部分。

---

## 1. AutoService 是什么（2 句话版）

多租户 AI 社交通道应用框架（客服/销售/教育），2026-05 跑在 macOS launchd 上。核心是 **Pipeline v2 三色编排（fast/cc 双相位 + 并发 ack + filler loop）+ cc_pool 多角色 Claude 子进程池 + 两棵树存储（git 框架内容 + 不入 git 的租户数据 `.autoservice/data/tenants/<tid>/`）+ 4 层 soul/skill 内容分层 + CR 驱动 sandbox→release 工作流**。avoid 列表：fork 架构、`runtime/sandbox/`、Feishu legacy、`PLACEHOLDER_ENABLED`。

---

## 2. 用户最关心：Pipeline v2 会话流程优化 12 项 → ezagent 迁移地图

按 P0/P1/P2 排序。**P0 = 客户直接感知，不迁就输；P1 = 成本/质量；P2 = 运维**。

| # | 优化 | AutoService 实现 | ezagent 落点 | 不变式风险 | 优先级 |
|---|---|---|---|---|---|
| 1 | **fast/cc 双相位**（prewarm 状态决定走 deepseek 直回 还是 cc + 并发 ack） | `orchestrator.py:135` `handle_message` + `_SessionState.phase` | domain/chat 新 `SessionOrchestrator` GenServer，state machine `:cold\|:warm` | 低 | **P0** |
| 2 | **并发 deepseek 抢 ack**（1.2s 内出 topic-anchored 第一帧 + intent skip） | `_fire_deepseek_ack_concurrent` (orchestrator.py:848) | `Task.Supervisor.async_nolink` + `Ezagent.Notifications.notify` 出（**合法 outbound**） | 中 — Task 必须 supervisor-linked，不能裸 spawn | **P0** |
| 3 | **FillerLoop**（5s±20% / max 3 / 静态库 fallback / `is_filler=true`） | `fast_agent/filler_loop.py` 全 132 行 | SessionOrchestrator 自己 `Process.send_after(self(), :tick_filler, …)` → `Notifications.notify` 出 | **关键 P14**：filler 必须 outbound，不能成 inbound 让其他 Kind 订阅（事故 2.1 形态） | **P0** |
| 4 | **cc_pool prewarm**（页面打开 fire-and-forget acquire_sticky） | `runner.py:99` + SSE `routes.py:218` | dispatch `:prewarm` action 给 cc agent URI（SpawnRegistry.spawn 已是 dispatchable） | 低 | **P0** |
| 5 | **Side-channel + preamble 剥离**（`[线索]` SIDE 分流 / `请稍等…` strip） | `_SideChannelStrippingSink` + `preamble_stripper.py` | domain/chat 新 `OutputFilter` Behavior，作 cc agent 出口 wrapper；strict + flexible 双 regex + CI lint | 低（纯 outbound transform） | **P0**（信任/PII 红线） |
| 6 | **KB MCP prefetch**（cc 跑前 top_k=10 注入 `<kb_context>`，17-19s → 5-9s） | `runner.py:168` + `queries.py:295` | 新 `ezagent_domain_kb`，Behavior `Kb.Search`；orchestrator 在 cc dispatch 前先 dispatch KB | 低 — 两次 dispatch 合法 | **P1** |
| 7 | **观测性 perf telemetry**（`[v2-perf]` 每轮结构化 + `reason=` 失败字段） | orchestrator.py:793 + 通篇 logger | `[:ezagent, :session, :turn, :stop]` telemetry event + measurements map | 低 | **P1** |
| 8 | **熔断 V1**（deepseek 3 次失败永久回退） | `_FAILURE_THRESHOLD=3` (orchestrator.py:44) | SessionOrchestrator state `fast_ack_disabled?` flag；**应抽到 core 做 `Ezagent.CircuitBreaker` primitive**（P22 reliability-in-core） | 中 — 不要 plugin 自造 breaker | **P1** |
| 9 | **短消息 / 短输入 length-skip**（zh<8 / en<15 全关 ack+filler；voice 例外） | `_ack_skip` (orchestrator.py:382-405) | `InputClassifier.short?/1` helper + channel-aware（voice 必发 ack）；channel 信息在 invocation `ctx` 加字段 | 低 | **P1** |
| 10 | **transcript token-limit 截断**（默认 1500） | `PIPELINE_V2_TRANSCRIPT_TOKEN_LIMIT` | domain/chat 加 `TranscriptCompactor` 纯函数 | 无 | **P2** |
| 11 | **Skill 热重载 vs Soul spawn-time 烧死** | `_read_skill` per query 无缓存 vs SDK system_prompt | skill 走 SessionTemplate `working_directory` + MCP（已对齐 commit 18099a7）；soul 进 Template Class `template_data`（必须重启） | 低 | **P2** |
| 12 | **Tier upgrade（haiku→sonnet 原地切）** | `cc_pool.py:2581` `client.set_model()` | **结构性 gap** — `claude` CLI 无 in-place model API；ezagent 等价是 dispatch `:swap_model` → terminate + respawn（**丢上下文**） | 高 — 写 Decision Log 标 deferred | **P2** |

**dispatch-only-path 兼容性总纲**（P14 守护）：

- `inbound`：客户消息 / prewarm / cc query = `Ezagent.Invocation.dispatch/1`（唯一入口）
- `outbound`：fast ack / filler / cc 流式 token = `Ezagent.Notifications.notify/2` 或 `ExternalMirror.Publisher` event stream（已 CI 守护的合法路径）
- **永远不要**让 FillerLoop "广播 filler 给 session 让 session 再 dispatch 给客户"——那是 inbound 路径，事故根因

---

## 3. 基础架构映射要点（cc_pool / 入站 / state）

- **cc_pool（3972 行 Python，60% 是"管 N 个 cc 子进程"）**→ ezagent **不要新造池抽象**（P8 少发明多装配）。正确映射：每个 (workspace, role) 是 N 个 `entity://agent/<workspace>/cc_<role>_<idx>` Agent Kind，由 WorkspaceLoader 在 `agent_slots: [%{role: :cc_customer, prewarm: 3}]` 声明性预声明（cc plugin `application.ex:118` 的 `after_boot/0` 已经是钩子）。
- **sticky binding** = `session://default/<workspace>/<conv>` 绑 agent，走 `WorkspaceRegistry.bind/2`（不变式 #4 + P17）。chat_id→agent 归属由 Session Kind 持有，**不是池外 dict**。
- **`asyncio.Lock` per-conv 串行化** → OTP 天然按 mailbox 串行，**lock 整类消失**——这是 P8 的最大收益点。
- **入站三通道** → P12 Adapter pattern：web SSE / WS / voice 三个 plug，只做 "parse inbound → `Invocation{}` → dispatch"，业务全部在 dispatch 后；voice 媒体字节流**不进 dispatch**（外部 SFU），只 ASR-final 文本进。

---

## 4. 业务能力映射要点（4 层内容 / 两棵树 / CR / CapBAC）

- **4 层 soul/skill** → L0/L1/L2 共用 Template Class，L1/L2 用 slot 命名约定区分（不要每个 industry 多一个 Class）；L3 = SessionTemplate per-tenant fork（**config only**，不变式 #10）；priority 合成放 **加载期** 纯函数，**不要**在 Chat Behavior 运行时做。
- **两棵树 + unit address** → SPEC v3 URI 映射示例：
  - `tenants/cinnox/customer/identity@soul_section` → `template://soul_section/cinnox/customer.identity`
  - `tenants/cinnox/-/kb-chunk-abc@product_knowledge` → `resource://kb_chunk/cinnox/abc`
  - `_framework/customer/identity@soul_section` → `template://soul_section/system/customer.identity`
- **CR 是 `entity://cr/<workspace>/<id>` Kind**（不是 session — CR 跨多次操作存活的持久聚合），actions: create/edit/publish/revert；`compute_sandbox_diff` **白送**给 `kind_snapshots`（P22）；`sandbox_locks` 表 + `sandbox_snapshot.py` 整模块直接砍掉。
- **CapBAC**：master_admin = `workspace://system` 成员（不变式 #13），不要发 `:any` cap（anti-pattern）；tenant_admin **当前不能干净表达** — ezagent capability 只有 `{:within_session, _}` / `{:spawned_by, _}` 形状，缺 `{:within_workspace, _}`。这是 **HIGH 风险，迁移前必须先在 ezagent 立项**。
- **lead 销售线索 / `[线索]` SIDE 出口** → ExternalMirror Domain（不变式 #15），per-binding crash isolation + FacadeNonceTable + 两级监督树 **全部白送**。

---

## 5. 关键张力：全迁 vs 混合（两个对立观点）

**支持全迁的论据**（来自 infra / business / perf 三个视角）：

- Pipeline v2 的 `asyncio.Lock` per-conv、cc-dot artifact race、`_STATES` 全局 dict 在 OTP 模型里**根本不存在**
- CR / snapshot / per-tenant 隔离三块都能用 ezagent 核心原语替换自造轮子
- workspace_uri NOT NULL + cross-workspace deny 是 Python 当前没有的结构性保证

**反对全迁的论据**（来自 AutoService 反向视角，真诚批判）：

- **storage v3 vs 6-scheme allowlist 是结构性冲突** — L0/L1/L2 系统/平台/行业层在 ezagent 找不到位置，硬塞要 Allen 改架构（阻塞项）
- **voice 在 ezagent 是 explicit out-of-scope**（anti-patterns.md:50 媒体流不进 dispatch），AutoService 4601 行 voice 子树搬不过去
- **cc_pool `set_model` 是 SDK 协议层 API**，erlexec 拉裸 CLI 无等价；要么 600-1000 行重写 control protocol，要么双层 sidecar（资源开销 +30-50%）
- **ROI 不对**：AutoService 痛点是"加功能慢"，OTP 治"系统不可靠"治不了前者
- **沉没成本** ~12000 行核心 Python + admin portal V2 React，全部重写 6-9 工程师月，第一年 bug rate 必然高于现状

---

## 6. 推荐路径

**Step 1（立即，2-3 工程师月）：混合方案 + 吸收 P0 优化**

- ezagent 当 **identity + workspace + routing + audit 底座**，AutoService Python 当业务大脑
- **同时**在 ezagent 的 chat domain（`ezagent_domain_chat` + 新 `ezagent_plugin_*`）实现 §2 表里的 **P0 五项**（fast/cc 双相位、并发 ack、FillerLoop、prewarm、output filter），让 ezagent 原生的 chat 走出 AutoService 同级别的会话体验
- 跑 6 个月，观察信号

**Step 2（条件触发，3-6 工程师月）**：

- 信号 A：租户量 > 200 + cc_pool GC 卡顿 → 把 cc_pool 也搬到 ezagent
- 信号 B：admin portal 引发其他租户雪崩 → 把 CR 流程搬到 ezagent
- 都未触发 → 永久保持混合方案

**先决条件（在开始 Step 1 业务侧迁移前必须解决，无法绕过）**：

1. **HIGH** — ezagent capability 加 `{:within_workspace, _}` 形状，否则 tenant_admin 权限无法表达，第一天就要绕 cap 触发 anti-pattern
2. **HIGH** — Template Class 加声明式 cross-layer lint hook（防 L3 越权改 L1 域规则）
3. **MEDIUM** — `Ezagent.CircuitBreaker` core primitive（避免 plugin 自造熔断违反 P22）

---

## 7. 最不该做的事

**因为 "ezagent 设计更优雅" 这种审美驱动启动全迁** — ezagent 的 17 条 invariant + grill 文化是为 message router 工作量身定做，AutoService 是 AI 客服应用，业务形状不是 router，强搬等于"用 OpenAPI 工具链写报表系统"，不会比现状好。**先用混合 + P0 优化拿 80% 收益，剩下 20% 等信号触发再说**。

---

## 参考

- AutoService overview: `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\autoservice-overview.md`（2026-05-26 运行真实态）
- Pipeline v2 session flow: `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\2026-05-07-pipeline-v2-session-flow.md`
- Storage v3: `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\2026-05-22-unified-storage-v3.md`
- ezagent design principles: `.claude/skills/ezagent-developer/references/design-principles.md`（P1-P27）
- ezagent invariants: `.claude/skills/ezagent-developer/references/architecture-invariants.md`（17 不变式）
- ezagent anti-patterns: `.claude/skills/ezagent-developer/references/anti-patterns.md`
- URI SPEC v3: `docs/notes/uri-design.md` §5
