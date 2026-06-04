# AgentBridge PR-E — domain_instance_message Layer Purity

本 PR 在 PR-D 已经把 Agent chat delivery 迁到 AgentBridge 之后，删除
最后一个 `ezagent_domain_instance_message -> ezagent_plugin_cc` 依赖。

范围：
- 从 `apps/ezagent_domain_instance_message/mix.exs` 删除
  `{:ezagent_plugin_cc, in_umbrella: true}`。
- 删除该依赖对应的临时 `layer-violation-exempt` 标记。
- 将 `Ezagent.Orchestrator.McpSocket` 改为使用
  `Ezagent.AgentBridge.TokenStore`。
- 在 `layer_purity_test` 中新增基于 AST 的扫描，覆盖
  `apps/ezagent_domain_*/lib/**/*.ex`。

新的 invariant 会捕获真实代码引用，例如
`alias EzagentPluginCc.TokenStore` 或 `EzagentPluginCc.BridgeRegistry`。
它有意忽略注释、moduledoc、docstring 和其他字符串字面量，因此历史说明
可以继续留在文档里，不需要伪造 suppress 标记。

不在本 PR 范围内：
- Codex plugin 实现。
- 删除 deprecated cc 兼容 shim。
- 删除 `/cc_socket` 或 `cc:bridge:*` deprecation-window alias。

本 PR 完成后，`ezagent_domain_instance_message` 的 bridge 相关行为只通过 domain
abstraction 路由。这样 PR-G 添加 codex agent flavor 时，不会继承 cc
plugin 依赖。
