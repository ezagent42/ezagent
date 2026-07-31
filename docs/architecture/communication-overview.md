# Communication Overview — IM → Session → Agent

> **Durable architecture reference.** How a message flows from an external IM channel, into a session, out to the session's member agents, and back. Keep this current as the code evolves — it is the map for any work touching messaging, routing, the agent bridges, or the im/session/agent domain split. (Extracted 2026-06-12 from the unified-agent-session-transport research; `file:line` citations are point-in-time — verify against current code.)

## The flow at a glance

```
external IM (Feishu/Slack)
  │  webhook / WS long-connect
  ▼
InboundDispatcher.dispatch/1        ── resolves sender→caller, @mentions, chat_id→session_uri
  │  builds Ezagent.Message, dispatches  <session_uri>?action=chat.send   (mode :call)
  ▼
SESSION  ── Chat.handle_send/2
  │  persist (MessageStore) → Routing.Resolver (single source of truth) → fan-out
  │  default rule {:always} → ["$session_users", "$mentions"]
  │     every USER member always receives; an AGENT receives only when @mentioned
  ▼  for each recipient: cast  <recipient>?action=chat.receive
ENTITY.receive   ── one action, branches by kind_module
  ├─ Entity.User  → inbox / cursor-ring slice (notification surface)
  └─ Entity.Agent → AgentBridge.deliver → flavor adapter ──┐
                                                            ├─ cc    → WS Channel → claude MCP-bridge subprocess → live claude
                                                            ├─ codex → WS Channel → codex bridge subprocess
                                                            └─ curl  → in-process HTTP LLM call (separate CurlAgent Kind, no bridge)
  agent reply: sidecar `reply` tool (cc/codex) / in-handler dispatch (curl) → chat.send back into the session
```

**Key property:** the IM layer already only addresses `session://` URIs (never agents directly), and delivery is already "session → members via a unified `chat.receive`" through the routing layer. The `session.send |> entity_type.receive` shape exists in skeleton today; it is convention, not yet structure.

## 1. IM ingestion: external message → session message

Two transports feed one dispatcher, but only one is exposed:
- WS long-connect — `EzagentPluginFeishu.WsClient` (`.../ws_client.ex:222`). **The live, authenticated production transport.**
- HTTP webhook — `EzagentPluginFeishu.WebhookPlug.call/2` (`apps/ezagent_plugin_feishu/.../webhook_plug.ex`). **Route removed for #204** (unauthenticated public endpoint → forged-`open_id` impersonation). The plug is retained but **unmounted**; re-exposing it requires Encrypt-Key/signature verification first.

Both call `EzagentPluginFeishu.InboundDispatcher.dispatch/1` (`.../inbound_dispatcher.ex:58`), which: resolves sender → caller URI + caps (`SenderResolver`, `:64`); extracts `@`-mentions (`MentionParser`, `:89`); resolves `chat_id → session_uri` via `InboundChatLookup` reading the generic `external_mirror_bindings` table (fails closed on an ambiguous multi-session binding, `:174`); then in `dispatch_to_session/5` (`:248`) builds `Ezagent.Message.new(...)` (`:280`), forms `<session_uri>?action=chat.send` (`:286`), and `Ezagent.Invocation.dispatch/1` with `mode: :call` (`:292`).

The external message **becomes a session message at the `chat.send` dispatch**. There is no named `session.send` entry yet — the plugin reaches the Chat Behavior's `:send` action URI directly. `:call`-over-`:cast` is intentional (Decision #134) so cap-denial bubbles back to the human.

## 2. Session → agent delivery (the fan-out)

`Ezagent.ActionSet.Chat.handle_send/2` (`apps/ezagent_domain_instance_message/.../chat.ex:429`): persist via `MessageStore.write/2`; resolve recipients via `Ezagent.Routing.Resolver.resolve_with_ctx/4` (`:483`) — **the single source of truth for "who receives"; no hardcoded fan-out**. Default rule `{:always} → ["$session_users", "$mentions"]` (`default_rules.ex:90`): every **User** member always receives; an **agent** receives only when `@`-mentioned. Per recipient (`:512`): cross-session (`scheme == "session"`) re-enters another session's `chat.send`; otherwise `Delivery.dispatch_receive_call/3` (`chat/delivery.ex:119`) casts `<recipient>?action=chat.receive` (`mode: :ignore`). Also emits `{:notify, session_events_topic, {:chat_message, ...}}` for the LiveView stream.

## 3. The entity-communication pattern (already partially unified)

`Ezagent.ActionSet.Chat` registers `:receive` on **both** `Entity.User` and `Entity.Agent`; `handle_receive/2` (`chat.ex:559`) branches on `ctx[:kind_module]`:
- `Entity.User` → records `:last_received` + cursor-ring slice (inbox/notification surface).
- `Entity.Agent` → `Delivery.deliver_agent_receive/2` → builds a flavor-neutral `Ezagent.AgentBridge.Payload` → `AgentBridge.deliver_ensuring*`.

So `session.send |> entity_type.receive` **partially exists**: one `chat.send` fans out, one `chat.receive` branches User-vs-Agent. Missing for a clean model: it is a single Behavior with an internal `case` (not a polymorphic per-entity-type `receive`), and a third flavor (`curl`) bypasses this Chat `:receive` entirely (§5).

## 4. The claude-code MCP-subprocess transport (the constraint)

There are **two** claude-code transports, both **subprocesses of `claude`**, both reaching the BEAM over a WS Phoenix Channel:

**(a) Agent CHAT bridge** (inbound delivery + outbound reply): Python sidecar `apps/ezagent_plugin_cc/priv/python/ezagent_mcp_bridge.py` (MCP server exposing the `reply` tool) ↔ `Ezagent.AgentBridge.Channel`/`Socket`, topic `agent_bridge:<flavor>:<agent_uri>`. Inbound: `EzagentPluginCc.BridgeAdapter.deliver/2` → Channel `push "to_claude"` → sidecar feeds live `claude`. Outbound: sidecar `reply` tool → `BridgeAdapter.handle_client_event("reply", …)` → `chat.send` back into the session.

**(b) Orchestrator MCP transport** (the 7 privileged orchestration tools): Python sidecar `apps/ezagent_domain_instance_message/priv/orchestrator_bridge.py` (a **second** MCP server) ↔ `Ezagent.Orchestrator.McpChannel`/`McpSocket`, topic `orch:bridge:<orchestrator_uri>`. `tools/list` served locally from a shipped schema; `tools/call` forwarded as a Channel push → `McpServer.handle_tool_call/3` under the orchestrator's delegated caps.

**Why it MUST be a `claude` subprocess:** a live `claude` cannot talk to an Elixir module — only to MCP servers listed in its config, over **stdio**. So the MCP server is necessarily a process `claude` spawns. **The load-bearing, un-unifiable part is the stdio-MCP-subprocess front end**; the WS Channel is just the shared BEAM back end.

**The "Claude Code channel" / dev-channels loader (the launch mechanism):** the cc chat bridge is the **`esr-bridge`** MCP server, written into the agent's `.mcp.json` by `EzagentPluginCc.McpConfigWriter` (`mcp_config_writer.ex:144`). Claude only LOADS a dev-channel MCP when launched with the **`--dangerously-load-development-channels`** flag (`ezagent_domain_pty/server.ex:43`, the `:dev_channels_dialog`); without it, `claude` prints `server:esr-bridge · no MCP server configured` and never connects (`mcp_config_writer.ex:23,175`). So "the Claude Code channel" = the `esr-bridge` dev-channel MCP, loaded via that flag; the cc Template Class wires the MCP configs into the `claude` argv (`cc_agent/spawn.ex:459`; claude merges MCP configs additively). **Only claude-code uses these** — codex has its own chat-bridge sidecar but no orchestrator MCP; curl uses neither.

## 5. Per-flavor agent receive/act — unified for cc+codex, divergent for curl

| flavor | `:receive` path | how the running agent receives | reply |
|---|---|---|---|
| **cc** | `Behavior.Chat` (Agent branch) → `AgentBridge` → `EzagentPluginCc.BridgeAdapter` | WS Channel `push "to_claude"` → MCP-bridge subprocess → `claude` | sidecar `reply` tool → `chat.send` |
| **codex** | `Behavior.Chat` (Agent branch) → `AgentBridge` → `EzagentPluginCodex.BridgeAdapter` | WS Channel `push "codex_turn"` → codex bridge subprocess | sidecar `reply` tool → `chat.send` |
| **curl** | **`Behavior.CurlAgent`** (own Behavior on the **separate `Entity.CurlAgent` Kind**) | **no bridge, no subprocess** — calls a remote LLM HTTP API in-process | in-handler `{:dispatch, %Cmd{}}` `chat.send` |

cc+codex share the `Behavior.Chat` Agent path; the flavor split happens **below** Chat inside `AgentBridge.deliver/2` (flavor → adapter, `agent_bridge/adapter.ex`). **curl is a separate Kind+Behavior** and does not participate — the real fork any "unified agent receive" must reconcile.

## 6. Dependency directions (today)

- `ezagent_domain_agent_bridge` depends only on `ezagent_core` — a clean leaf seam.
- `ezagent_domain_instance_message` (today's session-ish domain: Chat + Session + the orchestrator MCP) depends on `agent_bridge`, `pty`, identity, workspace, external_mirror — but **NOT** on any `plugin_cc/codex/curl`. Plugins register INTO it via the `Ezagent.Plugin` contract.
- Flavor adapters live in the plugins, which depend DOWN on the domains and register at boot.
- **Anomaly:** the orchestrator MCP transport lives **inside** `instance_message` (the session domain) even though it is a cc-flavor concern — the structural expression of "the orchestrator was special-cased at the session level." The target architecture relocates that transport to the cc plugin (one flavor adapter among three), leaving the session domain with only the session-management *logic*.

## Target (in-flight)

The im/session/agent 3-domain decomposition formalizes what is already skeletal: **im → session → agent, acyclic**; IM only addresses the session; the session forwards to members via the unified `entity_type.receive`; each agent flavor's transport (incl. claude-code's MCP-subprocess) sits as an adapter **under** `Agent.receive`, not as a session-level special case. See the unified-agent-session-transport design + the P5 collapse plan.
