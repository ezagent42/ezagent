# Phase 2 业务架构 / 流程总览（高层）

> 给你读的整体设计，不含实现细节。读完你应该能回答："客户怎么对话"、"operator 怎么接手"、"AI 个性化从哪来"。

## 角色（4 个 actor）

| 角色 | 在 ezagent 里是什么 | 持久? |
|---|---|---|
| **Customer（终端用户）** | 不是 Kind，不持久化。每次对话生成一个合成 URI `entity://user/<tenant>/customer_<id>` | 否，纯数据 |
| **cc agent（AI 客服）** | `entity://agent/<tenant>/cc_cust_<conv_id>`，一个 claude 子进程，带租户 soul | 每个对话一个，进程级 |
| **Session（对话）** | `session://default/<tenant>/<conv_id>`，一个 GenServer + PubSub 主题 | 每对话一个，便宜 |
| **Operator（人工客服）** | ezagent 普通 User `entity://user/<tenant>/<name>` + cap | 持久 User，但**不常驻 session** |

## 流程 1：客户和 AI 对话（核心路径）

```
浏览器/IM
  │ POST /api/customer/<tenant>/chat  {customer_id, text, conv_id}
  ▼
CustomerChatController (HTTP + SSE)
  │ 1. 校验 workspace 存在
  │ 2. 确保 session://default/<tenant>/<conv_id> 存在（per-conv，互不串）
  │ 3. ensure_cc_for_conv:
  │      - 创建 cc agent（幂等，每 conv 一个）
  │      - EagerBridge.ensure_bound!  ← 关键：自动唤醒 claude 的 esr-bridge MCP
  │      - 把 cc agent join 进 session
  │ 4. 打开 SSE 流，发 open 事件
  │ 5. 构造客户 Message（带 mentions:[cc_agent] —— 因为 ezagent 默认路由对 agent 是 mention-gated）
  │ 6. dispatch chat.send 到 session
  ▼
Session（chat.send 处理）
  │ 持久化消息 + 广播到 session 主题 + 按路由规则 fan-out
  ▼
chat.receive(cc agent)
  │ AgentBridge.deliver → 找到 bound 的 bridge channel
  ▼
esr-bridge（claude 内的 python MCP server，经 WS 连回 ezagent）
  │ 把消息作为 <channel source="esr-bridge"> 块推给 claude
  ▼
claude（system prompt = channel-protocol 前导 + 租户 soul）
  │ 生成回复，调 reply tool（带 session_uris=[meta.session]）
  ▼
回复经 bridge → ezagent → chat.send 回 session → 广播 session 主题
  ▼
CustomerChatController 的 SSE 循环收到 → 转成 message 事件 → 流回客户
  └ AI 回复（含 soul 个性化的事实 + 语气）→ SSE close(terminal)
```

**AI 个性化（soul）从哪来**：cc agent spawn 时，`--append-system-prompt` = `channel-protocol 前导` + `租户 soul 文件内容`。soul 文件路径按租户参数化（`poc/fixtures/plugins/<tenant>/souls/customer.md`，生产可配置）。前导保证 claude 守 channel 协议，soul 决定语气和事实。

## 流程 2：operator 监听 + 接手（你问的重点）

**关键回答**：operator **不是** session 的常驻成员，接手时**也不"加入" session**。模型是 **「观察者 + 外部 actor」**，不是「成员」：

```
operator 打开 /admin/customer_sessions（dashboard）
  │ 列出所有活跃 customer session（订阅各 session 主题，只读观察）
  ▼
点进某个 session → /admin/customer_sessions/<conv_id>
  │ mount 时 PubSub.subscribe(session 主题)  ← 只订阅，不 join 为 member
  │ 实时看到 customer ↔ AI 的完整对话
  ▼
点 "Take over" 按钮
  │ dispatch mode.set {mode: :takeover} 到 session  ← cap-gated
  ▼
Session 的 Mode Behavior 翻成 :takeover
  │ - 广播 "(客服已接管对话)" 系统通知到 session 主题 → 客户看到
  │ - 此后 AI 的回复被 gate：不再 fan-out 给客户（但仍持久化，operator 可见）
  ▼
operator 在 dashboard 输入框打字 → dispatch chat.send（用 operator 自己的 cap）
  │ operator 消息广播到 session 主题
  ▼
客户的 SSE 流收到 operator 消息 → 转给客户
```

**为什么是「观察者」而不是「成员」**：
- operator 通过**订阅 PubSub 主题**读对话（无需 join）
- operator 通过**dispatch cap-gated action**（mode.set / chat.send）写对话
- 这比"join 为 member"更通用：operator 是个外部 actor，读总线 + 发动作，不占 session 成员名额

**Mode 三态**（本期只实现 auto + takeover）：
- `:auto` — 纯 AI，operator 只观察
- `:takeover` — operator 直接对客户说话，AI 闭嘴，客户看到接管通知
- `:copilot`（预留未实现）— operator 给 AI 建议，AI 还是负责回复

## 已知的架构张力（你手测时会撞到，值得讨论）

**C3 channel 是请求/响应式（每条客户消息 = 一个 SSE 流，AI 回复后 close）**，但 operator 接手模型假设客户有一个**持久连接**让 operator 随时注入消息。两者有张力：

- 客户发消息 → SSE 流开 → 若此时 mode=takeover，AI 被 gate，没有 terminal AI 回复 → SSE 流挂着等到 operator 回复或 120s 超时
- operator 在这个窗口内回复 → 客户的 SSE 流收到（非 terminal）→ 客户看到
- 但如果 operator 超过 120s 才回复 → 客户 SSE 已超时关闭 → 客户要再发一条才能看到

**这说明什么**：要让 operator 接手体验顺滑，customer channel 可能需要从 C3(HTTP+SSE 请求响应) 升级到 **持久连接（C2 Phoenix.Channel WS）**，让 operator 能随时推消息给在线客户。这是 Phase 3 的一个候选决策点——本期先用 C3 验证核心，张力先记录下来。

## 抽象性 / 通用性自检（守约束 #2）

| 组件 | 是否 ezagent 通用 primitive 候选 | 还是 AutoService 专属 plugin |
|---|---|---|
| EagerBridge（自动唤醒 cc bridge） | ✅ 通用（任何非操作员入口都需要） | |
| Session Mode（auto/takeover/copilot） | ✅ 通用（任何有人工兜底的 chat 业务都要） | |
| Soul as Template arg | ✅ 轻度通用（cc-specific，但概念干净） | |
| channel-protocol 前导 | ⚠️ 介于两者（cc + bridge 特定，但所有用 bridge 的都要） | |
| Customer HTTP+SSE channel | | 🟡 客服形态，应进未来的 customer-chat plugin |
| Operator dashboard | | 🟡 客服形态，同上 |

所有 tenant 数据（soul 路径、workspace 名、agent URI、sandbox cwd）都参数化，无硬编码（守约束 #1）——这是未来抽 template 的前提。
