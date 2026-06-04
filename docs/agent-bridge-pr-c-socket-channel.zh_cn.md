# AgentBridge PR-C — Socket 与 Channel 提升

本 PR 将 bridge 使用的 Phoenix Socket 和 Channel 从
`ezagent_plugin_cc` 提升到 `ezagent_domain_agent_bridge`。

范围：
- `Ezagent.AgentBridge.Socket` 使用已提升的
  `Ezagent.AgentBridge.TokenStore` 认证 bridge sidecar。
- `Ezagent.AgentBridge.Channel` 负责 bridge join，并通过
  `Ezagent.AgentBridge.Registry` 绑定 channel。
- `EzagentWeb.Endpoint` 挂载新的标准 `/agent_bridge` socket。
- `EzagentWeb.Endpoint` 在两个 release 的弃用窗口内保留
  `/cc_socket` 作为 legacy alias。
- 标准 topic 使用 `agent_bridge:<flavor>:<agent_uri>`。
- 旧 cc topic `cc:bridge:<agent_uri>` 继续可用。
- `Channel.join/3` 校验 topic 中的 URI 必须等于 token 认证后的
  `socket.assigns.agent_uri`。
- 新生成的 cc MCP config 默认指向
  `ws://127.0.0.1:10042/agent_bridge/websocket`。
- cc Python bridge 脚本默认使用 `/agent_bridge`；如果显式指向
  `/cc_socket`，仍会选择旧的 `cc:bridge:*` topic。
- `EzagentPluginCc.Socket` 和 `EzagentPluginCc.Channel` 保留为
  deprecated delegating shim。

兼容性：
- 已在线的 cc sidecar 如果连接在 `/cc_socket` 并加入
  `cc:bridge:<agent_uri>`，会通过 legacy endpoint mount 和 topic
  alias 继续进入同一套 Channel 逻辑。
- 已提升的 registry 沿用 PR-B 保留的历史 ETS 表名，因此 live bridge
  state 仍在同一张表中。
- cc 不再从 `EzagentPluginCc.Application.after_boot/0` 初始化 bridge
  registry；registry lifecycle 由 `EzagentDomainAgentBridge.Application`
  拥有。

不在本 PR 范围内：
- 将 `Chat.receive(Entity.Agent)` 改为调用
  `Ezagent.AgentBridge.deliver/2`。
- `Ezagent.AgentBridge.Payload` 与 BridgeAdapter delivery。
- 移除 `ezagent_domain_instance_message` 对 `ezagent_plugin_cc` 的依赖。
- 创建 `ezagent_plugin_codex`。

这个改动保持 cc 可运行，同时把 bridge transport 移到
plugin-independent 的 domain 层，为 PR-D 和 PR-G 增加 cc/codex 的
adapter-based delivery 打基础。
