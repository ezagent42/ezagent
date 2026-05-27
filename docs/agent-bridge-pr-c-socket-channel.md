# AgentBridge PR-C — Socket and Channel Promotion

This PR promotes the bridge Phoenix Socket and Channel out of
`ezagent_plugin_cc` into `ezagent_domain_agent_bridge`.

Scope:
- `Ezagent.AgentBridge.Socket` authenticates bridge sidecars with the
  promoted `Ezagent.AgentBridge.TokenStore`.
- `Ezagent.AgentBridge.Channel` owns bridge joins and registry binding
  through `Ezagent.AgentBridge.Registry`.
- `EzagentWeb.Endpoint` mounts the canonical `/agent_bridge` socket.
- `EzagentWeb.Endpoint` keeps `/cc_socket` as a legacy alias for the
  two-release deprecation window.
- Canonical topics use `agent_bridge:<flavor>:<agent_uri>`.
- Legacy cc topics using `cc:bridge:<agent_uri>` remain accepted.
- `Channel.join/3` verifies the topic URI equals the token-authenticated
  `socket.assigns.agent_uri`.
- New cc MCP configs default to
  `ws://127.0.0.1:10042/agent_bridge/websocket`.
- The cc Python bridge script defaults to `/agent_bridge` and still
  selects the legacy `cc:bridge:*` topic when pointed at `/cc_socket`.
- `EzagentPluginCc.Socket` and `EzagentPluginCc.Channel` remain as
  deprecated delegating shims.

Backward compatibility:
- Existing cc sidecars connected to `/cc_socket` and joined to
  `cc:bridge:<agent_uri>` continue using the same Channel code through
  the legacy endpoint mount and topic alias.
- The promoted registry keeps the historical ETS table name from PR-B,
  so live bridge state remains in the same table.
- cc no longer initializes the bridge registry from
  `EzagentPluginCc.Application.after_boot/0`; lifecycle ownership is in
  `EzagentDomainAgentBridge.Application`.

Out of scope:
- `Chat.receive(Entity.Agent)` rewrite to `Ezagent.AgentBridge.deliver/2`.
- `Ezagent.AgentBridge.Payload` and BridgeAdapter delivery.
- Removing `ezagent_domain_chat`'s dependency on `ezagent_plugin_cc`.
- Creating `ezagent_plugin_codex`.

This keeps cc operational while making the bridge transport
plugin-independent enough for PR-D and PR-G to add adapter-based
delivery for cc and codex.
