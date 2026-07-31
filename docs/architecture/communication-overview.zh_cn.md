# 通信全貌 — IM → Session → Agent

> **长期架构参考文档。** 描述一条消息如何从外部 IM 渠道进入 session、分发给 session 的成员 agent、再返回。随代码演进保持更新——任何动到消息/路由/agent bridge/im-session-agent 域拆分的工作都以此为图。（2026-06-12 从"统一 agent-session 传输"调研中提取；`file:line` 是时点引用，请对照当前代码核对。）

## 一图概览

```
外部 IM（飞书/Slack）
  │  webhook / WS 长连
  ▼
InboundDispatcher.dispatch/1        ── 解析 sender→caller、@提及、chat_id→session_uri
  │  构造 Ezagent.Message，派发  <session_uri>?action=chat.send   (mode :call)
  ▼
SESSION  ── Chat.handle_send/2
  │  持久化(MessageStore) → Routing.Resolver(唯一真源) → 扇出
  │  默认规则 {:always} → ["$session_users", "$mentions"]
  │     每个 USER 成员总收到；AGENT 只在被 @提及时收到
  ▼  对每个 recipient：cast  <recipient>?action=chat.receive
ENTITY.receive   ── 一个动作，按 kind_module 分支
  ├─ Entity.User  → 收件箱 / cursor-ring slice（通知面）
  └─ Entity.Agent → AgentBridge.deliver → flavor 适配器 ──┐
                                                          ├─ cc    → WS Channel → claude MCP-bridge 子进程 → 活的 claude
                                                          ├─ codex → WS Channel → codex bridge 子进程
                                                          └─ curl  → 进程内 HTTP LLM 调用（独立 CurlAgent Kind，无 bridge）
  agent 回复：sidecar `reply` 工具(cc/codex) / handler 内 dispatch(curl) → chat.send 回 session
```

**关键性质：** IM 层**已经只寻址 `session://` URI**（从不直接寻址 agent），投递**已经是"session → 成员、经统一的 `chat.receive`"**（走路由层）。`session.send |> entity_type.receive` 的形态今天已有骨架——但目前是**约定**、还不是**结构**。

## 1. IM 摄入：外部消息 → session 消息

两条传输喂给同一个 dispatcher，但只暴露一条：**WS 长连（`WsClient`，`ws_client.ex:222`）是线上唯一已鉴权的生产传输**；HTTP webhook（`EzagentPluginFeishu.WebhookPlug.call/2`）的**公网路由已按 #204 移除**（未鉴权公网端点 → 伪造 `open_id` 冒充），plug 保留但**已 unmount**,重新暴露前须先做 Encrypt-Key/签名校验。两者都调用 `InboundDispatcher.dispatch/1`（`inbound_dispatcher.ex:58`）。它：解析 sender→caller URI+caps（`SenderResolver`，`:64`）；抽取 @提及（`MentionParser`，`:89`）；用 `InboundChatLookup` 读通用 `external_mirror_bindings` 表把 `chat_id→session_uri`（多 session 绑定歧义时 fail-closed，`:174`）；然后在 `dispatch_to_session/5`（`:248`）构造 `Ezagent.Message`（`:280`）、组 `<session_uri>?action=chat.send`（`:286`）、`Invocation.dispatch/1` 以 `mode: :call`（`:292`）。

外部消息**在 `chat.send` 派发处变成 session 消息**。目前**没有具名的 `session.send` 入口**——插件直接够到 Chat behavior 的 `:send` 动作 URI。`:call` 而非 `:cast` 是有意的（Decision #134），让 cap 拒绝能冒泡回人。

## 2. session → agent 投递（扇出）

`Behavior.Chat.handle_send/2`（`chat.ex:429`）：`MessageStore.write/2` 持久化；`Routing.Resolver.resolve_with_ctx/4`（`:483`）解析收件人——**"谁收"的唯一真源，无硬编码扇出**。默认规则 `{:always} → ["$session_users", "$mentions"]`（`default_rules.ex:90`）：每个 **User** 成员总收到，**agent** 只在被 @提及时收到。对每个收件人（`:512`）：跨 session（`scheme=="session"`）重入另一个 session 的 `chat.send`；否则 `Delivery.dispatch_receive_call/3`（`chat/delivery.ex:119`）cast `<recipient>?action=chat.receive`（`mode: :ignore`）。另发 `{:notify, ..., {:chat_message,...}}` 给 LiveView 流。

## 3. entity 通信模式（已部分统一）

`Behavior.Chat` 在 **User 和 Agent 两个 Kind 上都注册了 `:receive`**；`handle_receive/2`（`chat.ex:559`）按 `ctx[:kind_module]` 分支：`Entity.User` → 记 `:last_received` + cursor-ring slice（收件箱/通知面）；`Entity.Agent` → `Delivery.deliver_agent_receive/2` → 构造 flavor-中立的 `AgentBridge.Payload` → `AgentBridge.deliver_ensuring*`。

所以 `session.send |> entity_type.receive` **已部分存在**：一个 `chat.send` 扇出、一个 `chat.receive` 按 User/Agent 分支。离干净模型还差：它是**一个 behavior 内部 case**（不是按 entity 类型多态派发的 receive）；且第三种 flavor（`curl`）**完全绕过**这个 Chat `:receive`（见 §5）。

## 4. claude-code MCP 子进程传输（约束）

有**两条** claude-code 传输，都是 **`claude` 的子进程**、都经 WS Phoenix Channel 到 BEAM：

**(a) agent CHAT bridge**（入站投递 + 出站回复）：python sidecar `ezagent_mcp_bridge.py`（暴露 `reply` 工具的 MCP server）↔ `AgentBridge.Channel`/`Socket`，topic `agent_bridge:<flavor>:<agent_uri>`。入站：`EzagentPluginCc.BridgeAdapter.deliver/2` → Channel `push "to_claude"` → sidecar 喂活的 `claude`。出站：sidecar `reply` 工具 → `handle_client_event("reply",…)` → `chat.send` 回 session。

**(b) orchestrator MCP 传输**（那 7 个特权编排工具）：python sidecar `orchestrator_bridge.py`（**第二个** MCP server）↔ `Orchestrator.McpChannel`/`McpSocket`，topic `orch:bridge:<orchestrator_uri>`。`tools/list` 本地从随附 schema 服务；`tools/call` 转成 Channel push → `McpServer.handle_tool_call/3`，在 orchestrator 被委派的 caps 下执行。

**为什么必须是 `claude` 子进程：** 活的 `claude` 不能调 Elixir 模块——只能调它配置里列的 MCP server、走 **stdio**。所以 MCP server 必然是 `claude` spawn 的进程。**承重、不可统一掉的是这个 stdio-MCP-子进程前端**；WS Channel 只是共享的 BEAM 后端。

**"Claude Code channel" / dev-channels 加载机制（启动关键）：** cc chat bridge 就是 **`esr-bridge`** 这个 MCP server，由 `EzagentPluginCc.McpConfigWriter` 写进 agent 的 `.mcp.json`（`mcp_config_writer.ex:144`）。claude 只有在用 **`--dangerously-load-development-channels`** flag 启动时才会**加载** dev-channel MCP（`ezagent_domain_pty/server.ex:43`，`:dev_channels_dialog`）；不加这个 flag，`claude` 会打印 `server:esr-bridge · no MCP server configured`、根本不连（`mcp_config_writer.ex:23,175`）。所以你记的"Claude Code channel" = 这个 `esr-bridge` dev-channel MCP，靠那个 flag 加载；cc Template Class 把 MCP config 写进 `claude` argv（`cc_agent/spawn.ex:459`；claude 加性合并）。**只有 claude-code 用这些**——codex 有自己的 chat-bridge sidecar 但没有 orchestrator MCP；curl 两者都不用。

## 5. 各 flavor 的 receive/act — cc+codex 统一、curl 分叉

| flavor | `:receive` 路径 | 活的 agent 怎么收 | 怎么回 |
|---|---|---|---|
| **cc** | `Behavior.Chat`(Agent 支) → `AgentBridge` → `EzagentPluginCc.BridgeAdapter` | WS Channel `push "to_claude"` → MCP-bridge 子进程 → `claude` | sidecar `reply` 工具 → `chat.send` |
| **codex** | `Behavior.Chat`(Agent 支) → `AgentBridge` → `EzagentPluginCodex.BridgeAdapter` | WS Channel `push "codex_turn"` → codex bridge 子进程 | sidecar `reply` 工具 → `chat.send` |
| **curl** | **`Behavior.CurlAgent`**（**独立 `Entity.CurlAgent` Kind** 上的自有 behavior） | **无 bridge、无子进程**——进程内调远端 LLM HTTP API | handler 内 `{:dispatch, %Cmd{}}` `chat.send` |

cc+codex 共用 `Behavior.Chat` 的 Agent 路径；flavor 分叉发生在 Chat **之下**、`AgentBridge.deliver/2` 里（flavor→适配器，`agent_bridge/adapter.ex`）。**curl 是独立 Kind+behavior**、不参与这套统一——是任何"统一 agent receive"必须调和的真分叉。

## 6. 依赖方向（当前）

- `ezagent_domain_agent_bridge` 只依赖 `ezagent_core`——干净的叶子缝。
- `ezagent_domain_instance_message`（当前"类 session"域：Chat + Session + orchestrator MCP）依赖 agent_bridge、pty、identity、workspace、external_mirror——但**不依赖任何 plugin_cc/codex/curl**。插件经 `Ezagent.Plugin` 契约注册进来。
- flavor 适配器在插件里，插件向下依赖域、boot 时注册。
- **异常：** orchestrator MCP 传输**在 `instance_message` 里**（session 域内），尽管它是 cc-flavor 的事——这正是"orchestrator 被在 session 层特殊化"的结构体现。目标架构把这个传输**迁到 cc 插件**（三个 flavor 适配器之一），session 域只留 session 管理**逻辑**。

## 目标（进行中）

im/session/agent 三域拆分把已有骨架**形式化**：**im → session → agent，无环**；IM 只寻址 session；session 经统一的 `entity_type.receive` 转发给成员；每个 agent flavor 的传输（含 claude-code 的 MCP 子进程）作为适配器落在 `Agent.receive` **之下**，而非 session 层的特殊通道。详见统一 agent-session 传输设计 + P5 collapse plan。
