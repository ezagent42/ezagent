# AgentBridge PR-D — Delivery Facade 与 cc BridgeAdapter

本 PR 将 `chat.receive` 的 Agent 分支从直接调用 cc registry，改为调用
AgentBridge domain facade。

范围：
- 新增 `Ezagent.AgentBridge.Payload`，作为 flavor-neutral 的 bridge
  消息 envelope。
- 新增 `Ezagent.AgentBridge.Adapter`，作为每个 agent flavor 的 bridge
  adapter behaviour。
- 新增 `Ezagent.AgentBridge.AdapterRegistry`，按 agent flavor 注册 adapter。
- 新增 `Ezagent.AgentBridge.deliver/2`，负责解析 live bridge channel 和
  adapter，并委托具体 adapter delivery。
- 当 adapter 尚未注册时，delivery 会进入有界的 5 秒 pending 队列；
  如果 adapter 一直未注册，则记录 telemetry/log 并 drop。
- 扩展 `Ezagent.Plugin.agent_flavors/0` declaration，支持可选
  `:bridge_adapter` 字段。
- 在 `Ezagent.Plugin.boot/1` 中，当 AgentBridge registry 可用时注册
  declared bridge adapter。
- 新增 `EzagentPluginCc.BridgeAdapter`。
- 在 `EzagentPluginCc.Application.agent_flavors/0` 中声明 cc adapter。
- 将 `Ezagent.Behavior.Chat` 的 Agent receive 分支改为调用
  `Ezagent.AgentBridge.deliver/2`。

兼容性：
- cc adapter 会把 `Payload` 转回历史的
  `%{"content" => text, "meta" => meta}` 形状，并向已绑定 Channel pid
  发送 `{:to_claude, payload}`。
- 在 PR-C 独立提升 Socket/Channel 之前，现有 cc Channel 仍可继续接收
  `{:to_claude, ...}`。
- `ezagent_domain_instance_message` 暂时仍保留对 `ezagent_plugin_cc` 的依赖，直到
  PR-E 删除该依赖并加强 layer-purity test。

不在本 PR 范围内：
- Socket 与 Channel 提升。
- 删除 `ezagent_domain_instance_message -> ezagent_plugin_cc` 依赖。
- Codex plugin 实现。

这是 codex 复用同一个 Agent Kind 与 bridge domain 之前必须完成的
layer-boundary 改造，避免继续通过 cc 命名模块路由。
