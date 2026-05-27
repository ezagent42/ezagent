# AgentBridge PR-B — TokenStore and Registry Promotion

This PR creates `ezagent_domain_agent_bridge` and promotes the shared
bridge token store and live bridge registry out of `ezagent_plugin_cc`.

Scope:
- `Ezagent.AgentBridge.TokenStore` owns per-agent connect tokens.
- `Ezagent.AgentBridge.Registry` owns `agent_uri -> channel_pid` bridge bindings.
- `EzagentPluginCc.TokenStore` remains as a docs-deprecated delegating shim.
- `EzagentPluginCc.BridgeRegistry` remains as a docs-deprecated delegating shim.
- The token YAML path remains unchanged:
  `$EZAGENT_HOME/<profile>/credentials/cc-channels.yaml`.
- The legacy cc PubSub topic remains available during the deprecation window.

Out of scope:
- Socket and Channel promotion.
- `/agent_bridge` dual mount.
- `Chat.receive(Entity.Agent)` rewrite.
- Codex plugin implementation.

This keeps existing cc bridge callers working while moving the shared
stateful primitives into a plugin-independent domain app.

The shims are documented as deprecated without compiler-level
`@deprecated` attributes in PR-B so existing `domain_chat` and
LiveView call sites do not introduce new warning-as-errors failures
before PR-D/PR-E migrate those call sites.
