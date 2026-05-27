# AgentBridge PR-G - Codex Plugin

本 PR 添加第一个非 cc 的 AgentBridge agent flavor：`codex`。

范围：
- 新增 `apps/ezagent_plugin_codex`。
- 在 `agent_flavors/0` 中声明共享 `Ezagent.Entity.Agent` Kind，
  `flavor: "codex"`，并设置
  `bridge_adapter: EzagentPluginCodex.BridgeAdapter`。
- 新增 `codex.agent` Template Class。
- 每个 agent 启动三类运行时：
  - Codex app-server sidecar（`codex app-server --listen unix://...`）；
  - 通过 `Ezagent.Domain.Pty` 暴露给用户交互的 Codex TUI；
  - 连接 AgentBridge 与 app-server 的 Python bridge sidecar。
- 将 `ezagent_plugin_codex` 接入 `ezagent_web`，确保 web release
  启动时 plugin 会 boot。
- 重构 `Ezagent.AgentBridge.Channel`，让 cc-specific join metadata
  和 push event 都通过 adapter callback 处理，而不是留在 domain
  channel 中。

Bridge 流程：
- `Ezagent.Behavior.Chat` 将 flavor-neutral 的
  `Ezagent.AgentBridge.Payload` 交给 codex adapter。
- `EzagentPluginCodex.BridgeAdapter.deliver/2` 向已连接 sidecar
  推送 `codex_turn` event。
- `priv/python/ezagent_codex_bridge.py` 通过 `thread/start` 和
  `turn/start` 把内容发送给 Codex。
- bridge 收集 `item/agentMessage/delta` notification，并在 turn
  完成后通过 AgentBridge 的 `reply` event 回传最终回复。

兼容性：
- `/cc_socket` 和 `cc:bridge:*` 在当前 deprecation window 内继续保留。
- cc sidecar 仍然收到 Phoenix event `"to_claude"`，但 domain channel
  不再包含 cc-only 的 `{:to_claude, ...}` 分支。
  `EzagentPluginCc.BridgeAdapter` 现在发出通用的
  `{:agent_bridge_push, "to_claude", payload}` tuple。

本 PR 使用 static-only verification。该分支没有运行任何 `mix` 命令。
