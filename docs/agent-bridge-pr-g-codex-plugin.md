# AgentBridge PR-G - Codex Plugin

This PR adds the first non-cc AgentBridge-backed agent flavor:
`codex`.

Scope:
- Adds `apps/ezagent_plugin_codex`.
- Declares `agent_flavors/0` for the shared `Ezagent.Entity.Agent`
  Kind with `flavor: "codex"` and
  `bridge_adapter: EzagentPluginCodex.BridgeAdapter`.
- Adds the `codex.agent` Template Class.
- Starts three per-agent runtimes:
  - a Codex app-server sidecar (`codex app-server --listen unix://...`);
  - a user-visible Codex TUI through `Ezagent.Domain.Pty`;
  - a Python bridge sidecar that connects AgentBridge to the app-server.
- Wires `ezagent_plugin_codex` into `ezagent_web` so the plugin boots in
  the web release.
- Refactors `Ezagent.AgentBridge.Channel` so cc-specific join metadata
  and push events live behind adapter callbacks instead of in the
  domain channel.

Bridge flow:
- `Ezagent.Behavior.Chat` delivers a flavor-neutral
  `Ezagent.AgentBridge.Payload` to the codex adapter.
- `EzagentPluginCodex.BridgeAdapter.deliver/2` pushes a `codex_turn`
  event to the connected sidecar.
- `priv/python/ezagent_codex_bridge.py` sends the content to Codex via
  `thread/start` and `turn/start`.
- The bridge collects `item/agentMessage/delta` notifications and sends
  the final answer back through AgentBridge's `reply` event.

Compatibility:
- `/cc_socket` and `cc:bridge:*` remain available for the active
  deprecation window.
- The cc sidecar still receives Phoenix event `"to_claude"`, but the
  domain channel no longer has a cc-only `{:to_claude, ...}` branch.
  `EzagentPluginCc.BridgeAdapter` now emits the generic
  `{:agent_bridge_push, "to_claude", payload}` tuple.

Static-only verification was used for this PR. No `mix` command was run
from this branch.
