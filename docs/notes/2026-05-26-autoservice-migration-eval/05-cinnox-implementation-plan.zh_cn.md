# cinnox-on-ezagent 阶段性落地方案（2026-05-27）

> 在 ezagent 上跑起 AutoService 真实租户 cinnox 的可执行 roadmap。
>
> **输入**：[00-synthesis](00-synthesis.zh_cn.md) 4 视角合成 + [PR #297](https://github.com/ezagent42/AutoService/pull/297) 的 7 PoC verdict（A1 soul + C3 SSE + per-conv session + bridge handshake open）。
>
> **方向**：用户已决定迁，不再讨论 hybrid vs full。本文给具体 milestone + 验收 + 工程量。
>
> **2026-05-27 patches**（按顺序）：
>
> 1. **约定 review**：经 [07-feasibility-vs-conventions](07-feasibility-vs-conventions.zh_cn.md)，9 处修正已 inline（M0 工程周 / M1 KB / M2 soul + filter tier / M3 SessionOrchestrator + FillerLoop + prewarm）
> 2. **术语纠正**：cinnox 是测试租户不是客户（见 [README](README.zh_cn.md#术语澄清2026-05-27-补含同团队纠正)）
> 3. **同团队纠正**：AutoService 与 ezagent 是同团队两项目，无跨团队协商成本——M0 等待时间从 6-12 周纠正为 1-2 周
> 4. **B1=Path B 决议**：EagerBridge plugin 原语（plugin tier，~1 周），不走 Path C cc-sdk-flavor agent。Path C 保留作未来 fallback

---

## 0. 范围边界（先明确不做什么）

- **在范围**：cinnox 租户的 customer chat 流（SSE / web）+ soul + KB + filter + 会话优化
- **不在范围**（这一波不动）：
  - Voice 通道（ezagent anti-pattern 明确 out-of-scope，留 AutoService Python）
  - Admin Portal V2（React + CR 流程，留 AutoService 继续）
  - Dream / Master rail / 计费 / 多平台管理
  - Feishu legacy
- **关键决策**：M0 阶段必须先解决，否则后面全悬空

---

## 1. 4 milestone 总览

| | M0 阻塞解除 | M1 最小能通 | M2 业务正确 | M3 UX 拉齐 | M4 性能/观测 |
|---|---|---|---|---|---|
| **目标** | 消除 ezagent 侧硬阻塞 | cinnox 能收能回 | 跟 AutoService 当前 cinnox 行为一致 | 感知延迟≈AutoService | 运维 + 长会话 |
| **可见性** | 内部 | 工程 demo | cinnox **影子流量**对比测试 | A/B 切流 | 全量 |
| **dev 工程周** | ~2-3（含 Allen brainstorm，同团队内部） | 3-4 | 4-6 | 6-8 | 2-4 |
| **AutoService 依赖** | 无 | KB 文件迁过来 | soul 文件 + directive registry | Pipeline v2 编排逻辑参考 | telemetry 字段 |

---

## 2. M0 — 阻塞解除（先决，同团队内部串行排期）

来自 4 视角 eval + PR #297 的 4 条硬阻塞：

| # | 问题 | 来源 | 解除路径 |
|---|---|---|---|
| **B1** | **cc bridge handshake** — `BridgeRegistry.lookup` 对 customer-inbound 永久 `:error`，silent drop | PR §4 实测 + eval 03 §4 prewarm naive | Allen 主持 brainstorm 决 Path B (`EagerBridge` plugin 原语) 或 Path C (新 cc-sdk-flavor agent) — **Path C 更对，对齐 AutoService 的 claude_agent_sdk 模型**。⚠️ **若 Path C**：触及 `Ezagent.Behavior.Chat`（BridgeRegistry.lookup 分发），不是纯 plugin 工作，需改 ~100-200 行 + 新 plugin 300-500 行 + brainstorm，**~2-3 周同团队内部排期**（不是跨团队等待——AutoService 与 ezagent 是同团队两项目）；详 [07 §1 Path C](07-feasibility-vs-conventions.zh_cn.md#path-c-新-cc-sdk-flavor-agent走-claude_agent_sdk-stdio-json) |
| **B2** | capability `{:within_workspace, _}` 形状缺失 | eval 02 §5 | ezagent 加 capability shape + P15 不变式测试。**虽然 cinnox 短期可绕过（只用 customer/operator session caps），但 admin portal 重写时必撞** — 排进 ezagent backlog。**M1/M2 阶段策略性推后到 M3+**（admin portal 留 AutoService 时不需要此 cap） |
| **B3** | ezagent #392/393/395/396 已开 issue 4 条 | PR README 提及 | 等 ezagent merge — empty env var / cap-grant parser / lazy-spawn / cc onboarding UX。⚠️ **#395 (dispatch lazy-spawn)** 触及 P14 dispatch 语义，cinnox **方案不应该依赖此修复** — M1 workspace boot 时**显式 spawn** cs_main agent（`Ezagent.SpawnRegistry.spawn_detailed/1`），不靠 dispatch 自动唤醒 |
| **B4** | `session://` 是 group-chat container — 必须 per-conv | PR §2 cross-cutting + 3 EXP-C 交叉验证 | **不阻塞**：约定使用 `session://default/cinnox/<conv_id>` per-conv URI，文档化（不新建 `conversation://` Kind） |
| **B5** | GLOSSARY.md "session" 条目暗含 group-chat 用法（PR 发现的"未明文约定"） | 07 §1 B4 | 更新 GLOSSARY.md "session" 条目：明确 "per-conversation 容器"，标 PR §2 实测为 source of truth |

**M0 工程量**（同团队内部排期，无跨团队协商成本）：

- **B1 决议（2026-05-27）暂定走 Path B**：`EzagentPluginCc.EagerBridge.ensure_bound!/2` plugin 原语。理由：纯 plugin 层、不触及 `Ezagent.Behavior.Chat`、~1 周可完成、不需要 Allen brainstorm 架构决议（plugin 内部 reliability primitive 是 plugin tier 责任）。**保留 Path C 作为未来 fallback**：若 EagerBridge 在多 inbound plugin 场景下重复出现 → 演变为 anti-pattern → 届时再升级到 cc-sdk-flavor agent
- **B2 within_workspace cap**：策略性推到 M3+，不阻塞 M0
- **B3 #395**：方案不依赖，并行修复不阻塞
- **B4/B5 GLOSSARY**：< 1 天

**M0 关键路径 ≈ 1-2 周**（B1=Path B plugin 工作 + B4/B5 文档更新，同团队 1 dev focus 时间）。建议跟 M1 准备工作并行起步。

⚠️ **早期版本** 估的 "2-6 周等待 / 6-12 周（若 Path C）" 是基于跨团队协商前提，**已纠正**——同团队两项目无协商成本（详 [README 术语澄清](README.zh_cn.md#术语澄清2026-05-27-补含同团队纠正) + [07 §2](07-feasibility-vs-conventions.zh_cn.md#2-m0-整体判定)）。

---

## 3. M1 — 最小能通（cinnox 能发能回）

**目标**：1 个客户发"你好" → 收到 cc 真实回复，per-conv 不串台，**没有任何 UX 优化**。

| 任务 | ezagent 对应 | cinnox 数据 |
|---|---|---|
| Workspace 建立 | `workspace://cinnox` + `WorkspaceLoader` 配置 | tenant id `cinnox` |
| cc agent 实例 | `entity://agent/cinnox/cs_main`，**采用 PR A1 verdict**（soul as Template arg） | cinnox soul `customer_soul.md` 全文 |
| Soul 注入 | cc agent template `soul_path` 参数 → cc spawn 时 `--append-system-prompt @file` | `plugins/cinnox/souls/customer_soul.md` |
| Customer 通道 | **采用 PR C3 verdict** — HTTP+SSE controller `/chat/cinnox/<conv_id>` | (新写 controller) |
| Session 模型 | per-conv URI `session://default/cinnox/<conv_id>`（PR 强证据） | conv_id 客户端生成 UUID |
| Customer principal | `entity://user/cinnox/customer_<id>`（principal-only，不建 Kind — PR §5 验证过） | cookie 派生 |
| KB MCP | cc plugin `--mcp-config` 加 `autoservice_kb` server（python sidecar via erlexec） | `.autoservice/data/tenants/cinnox/kb/kb.db` 直接挂载 |
| 入站校验 | `system://chat-router` SystemPrincipal cap 综合 customer dispatch | (沿用 PR 验证过的方案) |

**KB 怎么挂**（M1 关键决策 — 协议不匹配，需 spike 选型）：

- **不重写 KB MCP server**（AutoService `kb_mcp_server.py` 已成熟）
- ⚠️ **协议不匹配**：`ezagent_domain_python/server.ex` (699 行) 跑的是 **JSON-RPC sidecar**；`kb_mcp_server.py` 跑的是 **MCP stdio 协议** — 不能直接复用
- 3 个选项（详 [07 §3.4](07-feasibility-vs-conventions.zh_cn.md#34-medium--kb-sidecar-协议错配)）：
  - **(a)** cc CLI 的 `--mcp-config` 直接指向 Python 脚本，**绕开 ezagent_domain_python** — 简单但 BEAM 不管该子进程，crash 时 orphan
  - **(b)** 扩展 `ezagent_domain_python` 支持 MCP 协议 — 工程量
  - **(c)** 写 MCP↔JSON-RPC shim — 工程量
- **M1 现实选择 = (a)**，但 docs 须标注 "KB MCP server 不在 BEAM 监督树下，依赖 cc CLI 自管"
- **kb.db 文件直接复制过来**（or 共享挂载点）— 不变

**M1 验收清单**：

- [ ] 2 个并发客户对话不串台（PR §2 实测过的回归）
- [ ] cc 能调 KB tool 并返回 cinnox 真实文档片段
- [ ] cc reply 通过 SSE 流式返回客户端
- [ ] 整条 invocation 链 audit log 完整可查
- [ ] **没有 fast ack / filler / preamble strip / DIRECT_TRANSFER detect** — 故意留空

**M1 不做的事**（重要克制）：

- 不做 4 层 soul（直接把整份 cinnox L3 soul 当 Template arg）
- 不做 prewarm（每次首条消息冷启 cc，慢但能通）
- 不做任何 filler 安抚
- 不做 lead summary 出口

---

## 4. M2 — 业务正确（行为对齐 AutoService 现网 cinnox）

这一阶段把"客户感知的正确性"补齐 — 否则 M1 跑通但客户会看到内部 marker 泄漏 / 不会触发转人工 / lead 信息丢失。

| 任务 | ezagent 落点 | cinnox 数据来源 | 风险 |
|---|---|---|---|
| **4 层 soul 合成** | 加载期纯函数：`SoulComposer.compose(l0, l1, l2, l3)` → 写出合成文件 → cc Template `soul_path` 指向合成结果。⚠️ **M2 简化版**：合成结果先写文件（`.autoservice/data/tenants/cinnox/_compiled/soul.md`），可接受；**M3+ TODO**：改 Resource Kind 存进 `kind_snapshots`（workspace_uri NOT NULL），否则散落文件绕过不变式 #14 + GDPR delete / snapshot 不知道这些文件（详 [07 §3.3](07-feasibility-vs-conventions.zh_cn.md#33-medium--soulcomposer-输出落盘是-ezagent-persistence-盲区)） | cinnox 实际只 L0+L3，L1/L2 空；合成函数读 `agents/customer/soul.md` + `tenants/cinnox/sections/customer/*.yaml` | priority lint 缺失（eval 02 §7 标 HIGH） — M2 可先不上 lint，但加 brainstorm ticket |
| **preamble strip** | **plugin tier**（不进 core domain）：新 plugin `ezagent_plugin_autoservice_filters` 暴露 transform，cc agent 出口经 ExternalMirror Publisher Adapter 的 `event_to_payload/1` 调用，zh + en regex bank | `autoservice/preamble_stripper.py` 的 `_SHORT_LEAD_PREAMBLE` 整体迁过来 | regex bank 维护成本，AutoService 也在补 case |
| **DIRECT_TRANSFER 字面量 detect** | **plugin tier**（cinnox 特定）：`ezagent_plugin_cinnox` 暴露 transform：scan reply for 16-char 字面量 → emit `[direct_transfer]` telemetry + 给 SSE metadata 加 `directive: :direct_transfer` 字段给客户端拦截 | cinnox soul §12 已经告诉 cc 输出格式 | 输出格式漂移（cc 加引号 / xml）— 容错 regex 不能太宽 |
| **`[线索]` SIDE-channel strip** | **plugin tier**（cinnox 特定）：`ezagent_plugin_cinnox` 第二个 transform：split raw → `customer_text` + `lead_text` | wire format 文档：`docs/contracts/lead-summary-wire-format.md` + cinnox soul §13 字段词表 | strict + flexible 双 schema 一开始就上 |

> ⚠️ **tier 修正说明**：以上 3 个 filter 此前 plan 写成 `Ezagent.Behavior.Chat.OutputFilter` 是错误的 — 违反 P9（reads what data 决定 tier ownership）+ P12（Adapter pattern：协议/租户特定代码留 plugin）。preamble strip 是 framework 级（多租户共用），DIRECT_TRANSFER / `[线索]` 是 cinnox 特定，**全部归 plugin tier**。详 [07 §3.2](07-feasibility-vs-conventions.zh_cn.md#32-high--outputfilter-在错的-tier)。
| **Lead 出口到外部 CRM** | ExternalMirror Adapter `Ezagent.ExternalMirror.Adapter.CinnoxLeadCRM` + Binding | AutoService 当前 lead_store 接收方 endpoint | per-binding crash isolation 白送（不变式 #15） |
| **kb_escalation_keywords** | cc agent system prompt 注入额外段（compose 时拼） | `plugins/cinnox/kb_escalation_keywords.json` 已清空到只剩硬触发词 | cinnox 现状已极简，照搬就行 |
| **welcome message 开场白** | C3 SSE controller 在新 conv 建立时发第一条 message | `scripts/seed_cinnox_tenant.py` `CONFIG["welcome_message"]` | 简单字符串注入 |

**M2 验收**：cinnox **影子流量**测试 — 同一条客户消息 send to AutoService（生产）+ ezagent（影子），对比 cc reply 应该**功能等价**（不是字面相同，是同意图同覆盖）。差异手动 case-by-case 评估。

---

## 5. M3 — UX 拉齐（Pipeline v2 等价优化）

这一阶段把 eval 03 视角里的 P0 五项落地。**做完这一阶段 cinnox 才能 A/B 切流**。

| 优化 | 实现 | 关键防御（来自 eval 03 §14） |
|---|---|---|
| **fast/cc 双相位** | **Session Kind chat slice 新增字段**：`phase :: :cold \| :warm`、`deepseek_failure_count`、`fast_ack_disabled?`，snapshot-on-change（P22）。**不**起独立 GenServer | state per session-URI 必须由 Session Kind 持有（P3 KindRegistry 是权威 SoT）— 详 [07 §3.1](07-feasibility-vs-conventions.zh_cn.md#31-high--sessionorchestrator-应该是-session-kind-的-slice不是独立-genserver) |
| **并发 deepseek 抢 ack** | `Task.Supervisor.async_nolink` 跑 deepseek HTTP → 结果 emit `%Publisher.Event{kind: :fast_ack}`（同 FillerLoop 走 ExternalMirror Publisher 出口） | Task 必须 supervisor-linked 不裸 spawn；走 outbound 合法路径不违反 P14 |
| **FillerLoop** | Session Kind `Process.send_after(self(), :tick_filler, jittered_ms)` → handle_info 内 emit `%Publisher.Event{kind: :filler}` 走 **ExternalMirror Publisher event stream**（**不**走 `Notifications.notify` — 后者需 `:notify` cap，session 自身持有该 cap 会导致 spam 风险）；cap-gating 由 Publisher Adapter `cap_subject/0` 持有 | **绝不**新增 `:filler_inbound` topic（事故 2.1 形态）；filler emit 直接 outbound，不绕回 session inbound。详 [07 §3.5](07-feasibility-vs-conventions.zh_cn.md#35-low--filler-的-notificationsnotify-cap-来源未定义) |
| **prewarm** | **B1 决议走 Path B**（2026-05-27）：SSE controller mount 时调 `EzagentPluginCc.EagerBridge.ensure_bound!/2`，把 cc bridge 显式拉起。失败 fail-loudly。**M1 不做**（M1 接受首条消息冷启），M3 启动 | M0 B1 plugin 原语就绪后即可启用；同团队内部不依赖外部排期 |
| **熔断 V1 fallback** | Session Kind chat slice `fast_ack_disabled?` flag + 失败计数（同上 fast/cc 双相位 slice 字段）；3 次后只走 cc | 应上 `Ezagent.CircuitBreaker` core primitive 而不是 plugin 自造（P22）— 排进 ezagent backlog |

**M3 验收**：cinnox 影子流量对比 — **感知延迟**指标（first-token p50 / first-token p95 / full-reply p50）应该 ≤ AutoService 当前生产水平。

**M3 风险**：

- Pipeline v2 编排在 OTP 里写比 Python asyncio 更分散（eval 04 §2 警告，~800 行 + 6-8 GenServer）— **不要硬把 orchestrator 写成 deterministic 状态机**（ezagent anti-pattern），保持 LLM-driven triage（deepseek 决意图）
- deepseek API key 管理 — cinnox 还是租户共用？per-workspace？这是个新决策

---

## 6. M4 — 性能 + 观测 + 运维（可暂缓）

| 优化 | 优先级 | 备注 |
|---|---|---|
| KB MCP prefetch（17-19s → 5-9s） | P1 | cinnox 现在用 `mcp_only` 模式，迁过去先保持 `mcp_only` 即可；prefetch 走 `runner.py:168` 等价物 — 在 SessionOrchestrator dispatch cc 前先 dispatch KB.search 拿 top-10 |
| Per-turn telemetry `[v2-perf]` 等价 | P1 | ezagent telemetry event `[:ezagent, :session, :turn, :stop]` + measurements map（first_byte_ms / filler_count / cc_complete_ms / fast_skipped_reason） |
| Skill 热重载 | P2 | cinnox 现网没有 L3 自定义 skill（overview §4.3 提到），M4 暂不做 |
| Transcript token-limit 截断 | P2 | `TranscriptCompactor` 纯函数，cc agent build prompt 时调 |
| Short-input length-skip（zh<8/en<15） + channel-aware | P2 | UX 调优，第一版不上不致命 |

---

## 7. 显式留作后续 / 不做

| 项 | 处理 |
|---|---|
| Tier upgrade (haiku→sonnet `set_model`) | **结构性 gap，cinnox 永远不上**。cinnox 上 ezagent 后单一模型，cost trade-off 在别的层做 |
| Soul cross-layer priority lint | M2 跑通后单开 ezagent ticket，cinnox 阶段不必 |
| Admin portal / CR sandbox→release | 留 AutoService — cinnox 在 ezagent 跑，但 admin 仍在 Python 那边编辑 soul/KB，**文件落盘到 ezagent 能读到的目录**（共享 mount 或 git push 后 ezagent 端 pull）— 这是 hybrid 方案的具体落地点 |
| `workspace://system` 装 L0 framework soul | **M2 阶段不必**，cinnox L0 直接读 `agents/customer/soul.md` 文件，等多租户多 L1/L2 落地再走 `workspace://system` Resource Kind |

---

## 8. 工作量 + 关键决策点汇总

| Milestone | dev 周（1 dev focus） | 关键决策 / 阻塞 |
|---|---|---|
| **M0** | ~1-2 周（B1=Path B plugin 原语 + B4/B5 文档；同团队内部排期，无跨团队等待） | B1 走 Path B（2026-05-27 暂定）；Path C 留作未来 fallback |
| **M1** | 3-4 周 | KB sidecar 协议选型；C3 controller 写出来；workspace boot 显式 spawn cs_main agent |
| **M2** | 4-6 周 | 4 层 soul composer 形态；output filter plugin 拆分 |
| **M3** | 6-8 周（1-2 dev） | EagerBridge primitive 整合；circuit breaker 是 plugin 还是 core |
| **M4** | 2-4 周 | KB prefetch 是否值得（cinnox 当前 `mcp_only` 是否已可接受） |

**总工程周（同团队 1 dev focus）**：cinnox 在 ezagent 跑起来（M0+M1+M2）≈ **8-12 周**；UX 拉齐 A/B 切流（+M3）≈ **14-20 周**。

**Wall-clock 估算**（同团队还要分摊 AutoService 主线维护 + ezagent 平台演进 capacity）：

- **乐观**（dev focus + Allen review 优先级高）：M0+M1+M2 ≈ 3-4 个月
- **现实**（dev 容量竞争）：M0+M1+M2 ≈ 5-7 个月，A/B 切流 6-9 个月

---

## 9. 推荐起手三件事（下周就能做）

1. **画 cinnox 现网调用链全图**：从 cookie 派生 customer_id → `/chat/{tid}` SSE 端点 → orchestrator → cc_pool → KB MCP → cc reply → SSE 流回。**用 eval + PR verdict 的术语标注 ezagent 对应物**——这张图就是 M1 的 spec。
2. **启动 EagerBridge plugin 原语开发**（B1=Path B 已定）：`EzagentPluginCc.EagerBridge.ensure_bound!/2` plugin 内 helper，~1 周可完成。同步在 PR #297 §4 grill prep 里更新答案（4 问中至少 Q4 已选 Path B）。
3. **写一个 spike**：在 ezagent 起 1 个 Python sidecar 把 AutoService `kb_mcp_server.py` 跑起来，让 ezagent 的 cc agent 能成功调 `kb_search` 工具拿 cinnox 真数据。**实际 1.5-3 周**（不是 1 周）— 必须解决 MCP stdio vs JSON-RPC 协议选型（见 §M1 KB 段 3 个选项 + [07 §3.4](07-feasibility-vs-conventions.zh_cn.md#34-medium--kb-sidecar-协议错配)）。这是 M1 最大未知数。

这三件事完成后，M1 的 ticket 就能拆出来开始干。**B1=Path B + EagerBridge primitive 就绪 = M3 prewarm 可启动**，不需要等 Allen 进一步 brainstorm（已选 plugin tier 方案）。
