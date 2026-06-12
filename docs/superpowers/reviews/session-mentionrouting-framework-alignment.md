# Session + MentionRouting 方案框架合规评估

> 日期: 2026-06-12 | 对照: ezagent 设计原则 P1-P27

---

## 一、逐条评估

### Group A — 工程原则 (P1-P7)

| 原则 | 合规 | 评估 |
|---|---|---|
| **P1** Plugin-isolation | ✅ | autoservice 是纯 plugin (`ezagent_plugin_autoservice`)，不修改 core/domain |
| **P2** Let-it-crash | ✅ | 无 shim/whitelist/workaround。operator 接管 synthetic turn_id 是 bug 不是 workaround |
| **P3** Single SoT | ✅ | 每条消息一条路径: dispatch → Session → MessageStore。URI 是唯一身份标识 |
| **P4** Production-usability | ✅ | DevAutoLogin + 启动脚本 + 一键 seed，开发者体验优先 |
| **P5** UUID-canonical | ✅ | URI 是不可变标识 (`entity://<ws>/user/<name>`)，display name 不进 DB key |
| **P6** Completion-claim 需 invariant test | ⚠️ | Phase C 缺少 invariant test → 3 页面无声缺失。流程问题，非架构问题 |
| **P7** Converge to unified shape | ✅ | 所有消息收敛为 `%Invocation{}` → dispatch，CustomerLive 和 OperatorLive 走同一路径 |

### Group B — 架构与边界 (P8-P13)

| 原则 | 合规 | 评估 |
|---|---|---|
| **P8** 少发明多装配 | ✅⭐ | **最大优势**。Session、MentionRouting、chat.send、Turn、CustomerFeed 全部是已有平台能力，autoservice 只是组装。零新 Kind 类型、零新 scheme |
| **P9** "Reads what data" 决定 tier | ✅ | autoservice 读 `%Invocation{}` / `%Message{}` → 在 plugin 层正确；不把 plugin 逻辑放进 core |
| **P10** Shared referent 需 identity | ✅ | Session URI 是 shared referent。Customer、Operator、Agent 都通过 Session URI 交互 |
| **P11** Plugin 不引入 top-level scheme | ✅ | 所有 URI 使用已有 6 schemes: `session://`, `entity://`, `workspace://`, `system://` |
| **P12** Adapter pattern | ✅ | CustomerLive/OperatorLive 是 adapter: (1) UI event → `%Invocation{}`, (2) 渲染结果。业务逻辑在 Session/Chat/Turn Behavior 中 |
| **P13** Phoenix is transport | ✅ | 使用 Phoenix LiveView + PubSub + Router，不用 Controller/View/MVC |

### Group C — Dispatch & Runtime (P14-P19)

| 原则 | 合规 | 评估 |
|---|---|---|
| **P14** Dispatch 是唯一 Kind 间路径 | ✅ | 所有 Kind 间通信走 dispatch: `chat.send`、`turn.open`、`turn.claim`。PubSub 仅用于 view fan-out (`CustomerFeed.topic`、`Chat.session_events_topic`)，P14 明确允许 |
| **P15** CapBAC module references | ✅ | Roles 模块使用 `Ezagent.Capability` struct，behavior 是 module reference。Cap 按 workspace 作用域 |
| **P16** Kind lifecycle 单一入口 | ✅ | Session spawn 走 `Ezagent.Kind.spawn`。Agent 走 `Workspace.create_agent` / `add_template`。ReadyGate + PendingDelivery 由框架保证 |
| **P17** Workspace via URI structure | ✅ | Session URI `session://<ws>/cs/<name>` 中 workspace 是结构段。`WorkspaceRegistry.bind/2` 确保一致性 |
| **P18** Dispatch mode 是 transport 选择 | ✅ | CustomerLive 用 `:cast` (fire-and-forget)，OperatorLive 用 `:call` (TurnAdapter)。选择正确 |
| **P19** 三条 dispatch 卫生规则 | ✅ | 不 import Behavior 模块；不跨 Behavior 读 slice；telemetry 自动 |

### Group D — 持久化 & URI (P20-P22)

| 原则 | 合规 | 评估 |
|---|---|---|
| **P20** URI 6-scheme + 3-segment | ✅ | 所有 URI 合规。`entity://<ws>/user/<name>` (3-segment)，`session://<ws>/cs/<name>` (3-segment)，action via `?action=` query-string |
| **P21** Per-tenant DB workspace_uri | ✅ | MessageStore 通过 session_uri 定位 workspace（session URI 隐含 workspace） |
| **P22** Reliability primitives in core | ⚠️ | ReadyGate/PendingDelivery/Idempotency/Snapshot-on-change 由框架保证。**但 operator 接管有一个静默失败**: `_ = TurnAdapter.claim_turn(...)` 忽略返回值。修复方案 A 可解决 |

### Group E — Plugin Contract (P23-P27)

| 原则 | 合规 | 评估 |
|---|---|---|
| **P23** Plugin declare, don't call | ✅ | `application.ex` 实现 `Ezagent.Plugin` contract: `plugin_info/0`。Content plugin 通过 `put_env` 注入 Behaviors |
| **P24** Extend existing schemes | ✅ | `entity://<ws>/agent/curl_fast-<name>` — 在 entity scheme 的 agent type 下扩展 name prefix |
| **P25** Channel meta string-only | N/A | autoservice 不涉及 CC channel notification |
| **P26** SessionTemplate fork = config | N/A | autoservice 暂不使用 SessionTemplate |
| **P27** Silent drops to clients | ⚠️ | operator 接管 `_ = TurnAdapter.claim_turn` 是静默失败。修复后可解决 |

---

## 二、双重 PubSub 订阅分析

当前 CustomerLive 同时订阅两个 PubSub topic:

```elixir
# customer_live.ex:29-30
Phoenix.PubSub.subscribe(PubSub, CustomerFeed.topic(session_uri))
Phoenix.PubSub.subscribe(PubSub, Chat.session_events_topic(session_uri))
```

| 路径 | 触发条件 | 消息类型 | P14 合规 |
|---|---|---|---|
| `CustomerFeed.topic` | Turn.settle 后 | `:customer_delivery` → CustomerFeed.replay | ✅ view fan-out |
| `Chat.session_events_topic` | chat.send 后 | `:chat_message` → 直接渲染 | ✅ view fan-out |

**P14 明确允许**: "use it only for unknown-bystander view fan-out / telemetry — never inbound delivery"

两个 PubSub 都是 view fan-out，不是 Kind-to-Kind 投递。Kind-to-Kind 路径始终走 dispatch。

**设计考量**: 双重订阅是防御性设计。bot reply 当前不走 Turn（走 `chat.send` → `:chat_message`），而 settled Turn 消息走 `:customer_delivery`。如果 bot reply 未来改为走 Turn，可以去掉 `:chat_message` 订阅，只留 CustomerFeed。这不是架构违规，是 pragmatism。

---

## 三、当前方案 vs 引入 CsOrchestrator Behavior 的框架合规对比

| 原则 | Session + MentionRouting (当前) | + CsOrchestrator Behavior |
|---|---|---|
| **P8** 少发明多装配 | ✅ 零新抽象 | ⚠️ 新增 Behavior 模块 + TurnDriver |
| **P14** Dispatch-only | ✅ 路径简单 | ⚠️ agent reply 需改路由 (bridge → orchestrator.send) |
| **P11** 不引入新 scheme | ✅ | ✅ (Behavior 注册在已有 Session Kind) |
| **P16** Kind lifecycle | ✅ Session 复用框架 | ✅ Behavior 运行在 Session 进程内 |
| **P22** Reliability | ⚠️ operator 接管需修 | ✅ cancel+reopen 更可靠 |
| **P3** Single SoT | ✅ | ⚠️ orchestrator state + Session state 双 SoT |

---

## 四、结论

### 充分利用框架能力 ✅

Session + MentionRouting 方案**高度符合** ezagent 设计原则:

1. **P8 (少发明多装配)** — 这是方案最大的优势。autoservice 不发明任何新抽象，只组装 6 个已有平台能力: Session、MentionRouting、chat.send、Turn、CustomerFeed、CapBAC

2. **P14 (dispatch-only)** — 所有 Kind 间通信 100% 走 dispatch。PubSub 严格限定在 view fan-out

3. **P11/P24 (不引入新 scheme)** — 所有 URI 使用已有 6 schemes，entity scheme 的 agent type 通过 name prefix 扩展

4. **P20 (URI shape)** — 3-segment authority + query-string action，完全合规

5. **P22 (reliability)** — 框架 ReadyGate/PendingDelivery/Idempotency 全部生效，无需 plugin 层额外处理

### 两个已知问题 (非架构违规，是实现 bug)

| 问题 | 违反原则? | 修复 |
|---|---|---|
| operator 接管 synthetic turn_id | P22 (静默失败) + P27 (静默 drop) | 方案 A 最小修正 |
| bot reply 不走 Turn → 无 CustomerFeed 门控 | 无 — bot reply 应立即可见 | 不需要修 (设计选择) |

### 一个设计特点 (非违规)

双重 PubSub 订阅 (`CustomerFeed.topic` + `Chat.session_events_topic`) 在 P14 允许范围内。两个都是 view fan-out，不是 Kind-to-Kind。这是 pragmatism — bot reply 和 settled Turn 走不同事件，未来统一到 CustomerFeed 后可简化。

### 与引入 Behavior 方案的对比

当前方案在 **P8 (少发明多装配)** 和 **P3 (Single SoT)** 上优于 Behavior 方案。Behavior 方案在 **P22 (reliability)** 上更完整。对于当前 v2 需求，当前方案更符合框架哲学 — "组装已有能力" 优于 "发明新编排层"。
