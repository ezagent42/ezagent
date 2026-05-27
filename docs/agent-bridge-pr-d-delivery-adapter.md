# AgentBridge PR-D — Delivery Facade and cc BridgeAdapter

This PR moves the `chat.receive` Agent delivery branch from a direct
cc registry call to the AgentBridge domain facade.

Scope:
- Adds `Ezagent.AgentBridge.Payload`, a flavor-neutral bridge message
  envelope.
- Adds `Ezagent.AgentBridge.Adapter`, the per-flavor bridge adapter
  behaviour.
- Adds `Ezagent.AgentBridge.AdapterRegistry`, keyed by agent flavor.
- Adds `Ezagent.AgentBridge.deliver/2`, which resolves the live bridge
  channel and adapter, then delegates delivery.
- Buffers delivery for an unregistered adapter for a bounded 5-second
  window, then drops with telemetry/logging if the adapter never
  registers.
- Extends `Ezagent.Plugin.agent_flavors/0` declarations with optional
  `:bridge_adapter`.
- Registers declared bridge adapters during `Ezagent.Plugin.boot/1`
  when the AgentBridge registry is available.
- Adds `EzagentPluginCc.BridgeAdapter`.
- Declares the cc adapter from `EzagentPluginCc.Application.agent_flavors/0`.
- Rewrites `Ezagent.Behavior.Chat` Agent receive to call
  `Ezagent.AgentBridge.deliver/2`.

Compatibility:
- The cc adapter converts `Payload` back to the historical
  `%{"content" => text, "meta" => meta}` shape and sends
  `{:to_claude, payload}` to the bound Channel pid.
- The existing cc Channel can continue to receive `{:to_claude, ...}`
  while PR-C promotes Socket/Channel separately.
- `ezagent_domain_chat` still carries the temporary `ezagent_plugin_cc`
  dependency until PR-E removes it and strengthens layer-purity tests.

Out of scope:
- Socket and Channel promotion.
- Removing the `ezagent_domain_chat -> ezagent_plugin_cc` dependency.
- Codex plugin implementation.

This is the layer-boundary change needed before codex can share the
same Agent Kind and bridge domain without routing through cc-named
modules.
