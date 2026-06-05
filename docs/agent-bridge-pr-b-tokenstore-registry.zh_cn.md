# AgentBridge PR-B — TokenStore 与 Registry 提升到 Domain

本 PR 新增 `ezagent_domain_agent_bridge`，并把共享的 bridge token
存储与在线 bridge 注册表从 `ezagent_plugin_cc` 提升到 domain app。

范围：
- `Ezagent.AgentBridge.TokenStore` 负责每个 agent 的 bridge 连接 token。
- `Ezagent.AgentBridge.Registry` 负责 `agent_uri -> channel_pid` 在线绑定。
- `EzagentPluginCc.TokenStore` 保留为文档标记 deprecated 的 delegating shim。
- `EzagentPluginCc.BridgeRegistry` 保留为文档标记 deprecated 的 delegating shim。
- token YAML 路径保持不变：
  `$EZAGENT_HOME/<profile>/credentials/cc-channels.yaml`。
- legacy cc PubSub topic 在兼容窗口内继续可用。

不包含：
- Socket 与 Channel 提升。
- `/agent_bridge` 双挂载。
- `Chat.receive(Entity.Agent)` 重写。
- Codex plugin 实现。

这样可以保持现有 cc bridge 调用方继续工作，同时把共享的有状态基础设施迁移到不依赖插件的 domain app。

PR-B 中 shim 只做文档级 deprecated 标记，不使用会触发编译 warning 的
`@deprecated` 属性；否则在 PR-D/PR-E 迁移 `domain_instance_message` 与 LiveView 调用点之前，
会引入新的 warning-as-errors 失败。
