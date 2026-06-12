# Unified Agent–Session Transport — Research + Design Proposal

**Status:** RESEARCH + DESIGN PROPOSAL (not a plan, not implemented)
**Date:** 2026-06-12
**Branch:** `research/unified-agent-session-transport` (off origin/main @ #734 `d4aa1872`)
**Author:** Claude (Opus 4.8, ezagent-developer + elixir-phoenix-helper loaded)

> This document maps the CURRENT communication topology with file:line evidence,
> then proposes a unified `session.send |> entity_type.receive` design under the
> planned **im / session / agent** 3-domain split, and flags genuine OPEN
> QUESTIONS for Allen. Where the current code resists the unification, that is
> called out explicitly rather than papered over.

---

## 0. The goal (restated)

ezagent is being re-decomposed into three domains:

- **im** — external IM ingestion + outbound transport (Feishu/Slack webhooks & WS, the channel-server/gateway/sidecar).
- **session** — the session substrate: the Session Kind, Chat, session-management/orchestrator tools.
- **agent** — the Agent Kind + agent templates + per-flavor adapters.

Target communication shape:

1. **im communicates ONLY with the session** — never directly with an agent.
2. The **session forwards** each message to its member entities.
3. send/forward reuses one **entity-communication pattern** (user/agent unified):
   `session.send |> entity_type.receive` — the session dispatches to each member
   entity, and each entity TYPE (`user` / `agent`) has a `receive`.
4. The unified transport lives in **domain.session**.

Allen's CRITICAL constraint: the orchestrator MCP transport is **NOT a generic
Phoenix channel** — it is an **MCP server that runs as a SUBPROCESS of `claude`**
(listed in `claude --mcp-config`). That is why it was never unified into a
generic agent-MCP transport — each claude-code instance links its own MCP server
as a subprocess. This affects **claude-code ONLY**; codex/curl are unaffected.
The unified design must therefore accommodate claude-code's MCP-subprocess as a
**per-flavor specificity UNDER the unified agent `receive`**, not as a
session-level special case.

---

## 1. CURRENT-STATE COMMUNICATION MAP (with evidence)

### 1.1 IM ingestion: external IM message → session message

An inbound Feishu message enters through TWO transports that converge on ONE
dispatcher:

- HTTP webhook — `EzagentPluginFeishu.WebhookPlug.call/2`
  (`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/webhook_plug.ex:31`,
  hand-off at `:84`).
- WS long-connect — `EzagentPluginFeishu.WsClient`
  (`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/ws_client.ex:222`).

Both call the single transport-decoupled entry point
`EzagentPluginFeishu.InboundDispatcher.dispatch/1`
(`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex:58`).
That function:

1. Resolves the sender to a caller URI + caps via `SenderResolver.resolve/1` (`:64`).
2. Extracts `@`-mentions up front (`MentionParser.extract_agent_mentions/1`, `:89`).
3. Resolves `chat_id → session_uri` via `InboundChatLookup.resolve/3` (`:99`) —
   reading the generic `external_mirror_bindings` table; fails closed on an
   ambiguous (multi-session) binding (`:174`).
4. **Converts the IM event into a session message and dispatches it INTO the
   session**, in `dispatch_to_session/5`
   (`inbound_dispatcher.ex:248`): it builds `Ezagent.Message.new(caller_uri, body,
   mentions:, legend_triggers:)` (`:280`), forms the target
   `Ezagent.URI.with_action(session_uri, :chat, :send)` (`:286`), and calls
   `Ezagent.Invocation.dispatch/1` with `mode: :call` (`:292-299`).

**→ The external message becomes a session message at the
`<session_uri>?action=chat.send` dispatch.** Today this is the IM plugin
constructing a `Message` and hand-rolling a `chat.send` dispatch — there is no
named `session.send` entry interface; the plugin reaches for the Chat Behavior's
`:send` action URI directly. (Mode override `:call`-over-`:cast` is intentional
per Decision #134 so cap-denial bubbles back to the human —
`inbound_dispatcher.ex:36-44`.)

**Evidence the IM plugin already only talks to the session (not agents):** the
dispatch target is always a `session://` URI; agents are never addressed here.
Goal #1 is therefore ~80% already true in the Feishu path — but it is
CONVENTION, not STRUCTURE: nothing stops a future IM plugin from dispatching
`entity://agent/...?action=chat.receive` directly.

### 1.2 session → agent delivery (the fan-out)

The fan-out lives in `Ezagent.Behavior.Chat.handle_send/2`
(`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:429`):

1. Persist the message — `MessageStore.write/2` (`chat.ex:444`).
2. **Resolve recipients via the routing layer** — `Ezagent.Routing.Resolver.resolve_with_ctx/4`
   (`chat.ex:483-490`). This is the SINGLE source of truth for "who receives";
   there is NO hardcoded fan-out (Phase 4-completion PR 9, `chat.ex:457-461`).
3. The default routing rule is `{:always} → ["$session_users", "$mentions"]`,
   seeded by `EzagentDomainInstanceMessage.DefaultRules`
   (`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/default_rules.ex:90-91`,
   moduledoc `:21-26`). Mention-gating means: **every User member always receives;
   an agent receives only when mentioned** (`$mentions`). Rules persist in
   `RuleStore` / `MentionRouting` and load into a `RoutingRegistry`.
4. For each resolved recipient, dispatch (`chat.ex:512-522`):
   - cross-session (`recipient.scheme == "session"`) → `Delivery.dispatch_cross_session_call/2`
     (re-enters another session's `chat.send`).
   - otherwise (user or agent) → `Delivery.dispatch_receive_call/3`
     (`chat/delivery.ex:119`) — dispatches `<recipient>?action=chat.receive`
     with `mode: :ignore` cast (`:124-135`), then marks `:delivered` on success.
5. Also `{:notify, session_events_topic, {:chat_message, ...}}` for the LV chat
   stream (`chat.ex:548`).

**→ Delivery IS already "session → members" through a unified `chat.receive`
dispatch.** The session resolves members via routing and casts `chat.receive` to
each. This is the seed the unified design grows from — it is NOT ad-hoc.

### 1.3 The entity-communication pattern (ALREADY PARTIALLY UNIFIED)

`Ezagent.Behavior.Chat` registers `:receive` on **both** `Ezagent.Entity.User`
AND `Ezagent.Entity.Agent` (chat.ex action matrix moduledoc `:7-14`,
registration note `:150-156`). `handle_receive/2` (`chat.ex:559`) branches on
`ctx[:kind_module]`:

- `Ezagent.Entity.User` → records a `:last_received` + cursor-ring slice
  mutation; the runtime's SliceChange hook emits the notification
  (`chat.ex:561-604`). User "receive" = inbox/notification surface.
- `Ezagent.Entity.Agent` → `Delivery.deliver_agent_receive/2`
  (`chat.ex:606-611`, impl `chat/delivery.ex:207-276`): builds a
  flavor-neutral `Ezagent.AgentBridge.Payload` and hands it to
  `Ezagent.AgentBridge.deliver_ensuring*` (`delivery.ex:266-273`).

**→ The `session.send |> entity_type.receive` pattern PARTIALLY EXISTS TODAY:**
one `chat.send` fans out; one `chat.receive` action with a per-`kind_module`
branch (User vs Agent). What is missing for the goal: it is a single Behavior
with an internal `case`, NOT a clean per-entity-type `receive` dispatched
polymorphically; and a THIRD entity flavor (`curl`) does NOT use this Chat
`:receive` at all (see §1.5).

### 1.4 The claude-code MCP-subprocess transport (the constraint)

There are TWO distinct claude-code transports, both subprocesses of `claude`,
both reaching the BEAM over a WS Phoenix Channel:

**(a) The agent CHAT bridge** (inbound delivery + outbound reply):
- Python sidecar: `apps/ezagent_plugin_cc/python/ezagent_mcp_bridge.py` — an MCP
  server subprocess of `claude` exposing the `reply` tool.
- BEAM endpoint: `Ezagent.AgentBridge.Channel`
  (`apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/channel.ex`) +
  `AgentBridge.Socket`. Topic `agent_bridge:<flavor>:<agent_uri>`.
- INBOUND (session→agent): `EzagentPluginCc.BridgeAdapter.deliver/2`
  (`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/bridge_adapter.ex:17-24`)
  `send(channel_pid, {:agent_bridge_push, "to_claude", %{...}})`; the Channel
  `push`es it down the WS to the sidecar (`channel.ex:62-65`), which feeds the
  live `claude` process.
- OUTBOUND (agent→session): the sidecar calls its `reply` tool →
  `BridgeAdapter.handle_client_event("reply", ...)`
  (`bridge_adapter.ex:27`) → `dispatch_reply/5` → `chat.send` back into the
  session(s) (`bridge_adapter.ex:157-172`).

**(b) The orchestrator MCP transport** (the 7 privileged orchestration tools):
- Python sidecar: `apps/ezagent_domain_instance_message/priv/orchestrator_bridge.py`
  — a SECOND MCP server subprocess of `claude`, exposing
  `add_agent_slot / write_matcher / update_template / ...`.
- BEAM endpoint: `Ezagent.Orchestrator.McpChannel` + `McpSocket`
  (`apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/mcp_channel.ex`,
  `mcp_socket.ex`). Topic `orch:bridge:<orchestrator_uri>`.
- `tools/list` is served LOCALLY from a shipped schema file
  (`orchestrator_bridge.py:30-36, 427-428`); `tools/call` is forwarded as a
  Channel `mcp_tools_call` push (`orchestrator_bridge.py:351-399`) →
  `McpChannel.handle_in("mcp_tools_call", ...)` (`mcp_channel.ex:143`) →
  `McpServer.handle_tool_call/3`, run under the orchestrator's delegated caps.

**WHY it MUST be a claude-code subprocess (resolving the apparent contradiction
with "not a Phoenix channel"):** a live `claude` cannot talk to an Elixir module
— it can only talk to MCP servers listed in its `--mcp-config`
(`orchestrator_bridge.py:14-21`). So the MCP server is necessarily a process
`claude` spawns and speaks to over **stdio** (the MCP protocol). The Phoenix
Channel is merely the BEAM-side back-end the stdio bridge tunnels to. **The
load-bearing transport — the part that cannot be unified away — is the
stdio-MCP-subprocess front end.** The WS Channel back end is an implementation
detail that the cc bridge and the orchestrator bridge happen to share, but the
MCP server itself is per-`claude`-instance, linked at `claude` launch via
`--mcp-config`. The cc Template Class wires BOTH MCP configs into the `claude`
argv: `assemble_settings_mcp_args/3` (`cc_agent/spawn.ex:459`) emits the trusted
esr-bridge `--mcp-config` (claude merges MCP configs additively;
`cc_agent.ex:69-72`), and the orchestrator role additionally seeds the
orchestrator MCP config (`CcOrchestratorSeed`).

**Confirmed codex/curl do NOT use the orchestrator bridge:** the orchestrator
bridge env (`EZAGENT_AGENT_TOKEN`) is minted by `EzagentPluginCc.TokenStore`
(`orchestrator_bridge.py:55-58`) and the orchestrator is "a cc-flavored agent".
codex has its OWN chat-bridge sidecar
(`apps/ezagent_plugin_codex/priv/python/ezagent_codex_bridge.py` +
`EzagentPluginCodex.BridgeAdapter`, `deliver/2` pushes `"codex_turn"`,
`bridge_adapter.ex:15-27`) but no MCP-subprocess orchestrator surface. curl uses
neither (see §1.5).

### 1.5 Per-flavor agent receive/act — UNIFIED for cc+codex, DIVERGENT for curl

| flavor | `:receive` Behavior | how the running agent receives | how it replies |
|---|---|---|---|
| **cc** | `Ezagent.Behavior.Chat` (Agent branch) → `AgentBridge` → `EzagentPluginCc.BridgeAdapter` | WS Channel `push "to_claude"` to the MCP-bridge subprocess, which feeds `claude` | sidecar `reply` tool → `chat.send` |
| **codex** | `Ezagent.Behavior.Chat` (Agent branch) → `AgentBridge` → `EzagentPluginCodex.BridgeAdapter` | WS Channel `push "codex_turn"` to the codex bridge subprocess | sidecar `reply` tool → `chat.send` |
| **curl** | **`Ezagent.Behavior.CurlAgent`** (its OWN Behavior, registered for `(Ezagent.Entity.CurlAgent, :receive)`) | **NO bridge, NO subprocess** — `handle_receive/2` calls a remote LLM HTTP API in-process | in-handler `{:dispatch, %Cmd{}}` `chat.send` back to the session |

Evidence:
- cc/codex go through the shared `Behavior.Chat` because `Ezagent.Entity.Agent.behaviors/0`
  lists `Ezagent.Behavior.Chat` (`apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex:75-77`).
  The flavor split happens BELOW Chat, inside `AgentBridge.deliver/2` which
  resolves flavor → adapter (`agent_bridge.ex:11-19`, adapter behaviour
  `agent_bridge/adapter.ex:9-10`).
- curl uses a DIFFERENT Kind (`Ezagent.Entity.CurlAgent`) with its own Behavior
  registered for `:receive`
  (`apps/ezagent_plugin_curl_agent/lib/ezagent/behavior/curl_agent.ex:34-37, 82-89, 156`).
  It is fully in-process — no AgentBridge, no channel, no subprocess.

**→ "agent receives + responds" is HALF unified.** cc+codex share one path that
already de-special-cases flavor below the `AgentBridge.Adapter` behaviour. curl
is a SEPARATE Kind+Behavior, so it does NOT participate in that unification — its
`receive` is a parallel, independent implementation. This is the real fork the
unified design has to reconcile (see §2.3 and OQ-1).

### 1.6 Dependency directions TODAY

- `ezagent_domain_agent_bridge` depends ONLY on `ezagent_core`
  (`apps/ezagent_domain_agent_bridge/mix.exs:33`) — a clean leaf domain.
- `ezagent_domain_instance_message` (today's "session-ish" domain, holds Chat +
  Session + the orchestrator MCP) depends on `agent_bridge`, `pty`, identity,
  workspace, external_mirror, etc. (`mix.exs:31-55`) — but **NOT** on any
  `plugin_cc/codex/curl` (verified: no matches). Plugins register INTO it via
  the `Ezagent.Plugin` contract.
- The flavor adapters live in the plugins (`ezagent_plugin_cc`,
  `ezagent_plugin_codex`, `ezagent_plugin_curl_agent`), which depend DOWN on the
  domains and register adapters/behaviors at boot.
- **Anomaly:** the orchestrator MCP transport
  (`McpChannel/McpSocket/McpServer/McpRegistry/CcOrchestratorSeed/orchestrator_bridge.py`)
  lives INSIDE `ezagent_domain_instance_message` — i.e. inside the session domain
  — even though it is a cc-flavor agent concern. This is the chief structural
  expression of the "orchestrator was special-cased at the session level"
  problem the unified design targets.

---

## 2. PROPOSED UNIFIED DESIGN — `session.send |> entity_type.receive`

### 2.1 The single `session.send` entry interface (im → session, ONE point)

Promote the *implicit* "dispatch `chat.send` to a session URI" into an
**explicit named session interface** that im (and only im, and agent-reply, and
LV) call:

```
Session.send(session_uri, %Message{}, ctx)            # the ONE inbound point
  └─ dispatch <session_uri>?action=chat.send          # mechanically still Chat.:send
```

- This is a thin, named facade over today's `Chat.:send` dispatch
  (`inbound_dispatcher.ex:286` is its current open-coded form). It does not
  replace the routing/persist machinery — it NAMES the chokepoint so the
  invariant "im only talks to the session" becomes STRUCTURAL: the im domain
  depends on `Session.send/3` and has no symbol that can address an agent.
- It lives in **domain.session**. The im domain calls it; it never reaches an
  agent URI.
- Keep the `:call`-vs-`:cast` mode override as a parameter (Decision #134) so
  cap-denial still surfaces to the human (`inbound_dispatcher.ex:36-44`).

**This is mostly a RENAME + a boundary guard, not new machinery** — the fan-out
already lives behind `Chat.:send`. The value is making Goal #1 enforced by the
type/dependency graph instead of by convention.

### 2.2 The session forward → unified `entity_type.receive`

Keep the existing model (it already fits the goal) and tighten it:

```
Chat.handle_send                       # in domain.session
  ├─ persist (MessageStore)
  ├─ resolve recipients (Routing.Resolver — RuleStore/mentions UNCHANGED)
  └─ for each recipient:
       dispatch <recipient>?action=<entity_type>.receive   # the unified verb
```

The unified `entity_type.receive` is realized by registering a `:receive` action
**per entity Kind**, all behind the SAME action name + payload contract
(`%{message: %Message{}}`), so the session's forward loop is polymorphic over
entity type and does NOT branch on kind internally:

- `User.receive` — inbox/notification surface (today's User branch of
  `Chat.handle_receive`, `chat.ex:561-604`).
- `Agent.receive` — the agent receive (today's Agent branch, `chat.ex:606-611`),
  which routes DOWN to the flavor (§2.3).

**De-special-casing move:** split today's single `Chat.handle_receive/2` with its
internal `case ctx[:kind_module]` (`chat.ex:559-617`) into two registrations of
the same `:receive` verb — `Behavior.User.receive` and `Behavior.Agent.receive`
— each owning its entity-type concern. The session's forward loop stays
identical (it already dispatches `?action=chat.receive` to whatever the recipient
is). This is the literal `session.send |> entity_type.receive` shape.

**Reuse vs replace of routing:** REUSE `Routing.Resolver` + `RuleStore` +
mention-gating WHOLESALE. They answer "WHICH members receive" — orthogonal to
"HOW an entity receives". The unified `entity_type.receive` is the HOW; routing
stays the WHO. No replacement; the default rule
(`$session_users` + `$mentions`, `default_rules.ex:90`) is unchanged.

### 2.3 The agent `receive` routes to its flavor — claude-code MCP as a flavor adapter

`Agent.receive` does NOT itself know cc/codex/curl. It hands the message to a
**flavor adapter** — exactly today's `AgentBridge.deliver/2` →
`AgentBridge.Adapter` indirection (`agent_bridge.ex:11`, `adapter.ex`). The
flavor adapter is the SINGLE place flavor-specificity lives:

```
Agent.receive(message, ctx)                         # domain.session / agent — flavor-blind
  └─ AgentBridge.deliver(agent_uri, payload)        # resolve flavor → adapter
       ├─ cc     → EzagentPluginCc.BridgeAdapter    # WS push "to_claude" → MCP-bridge subprocess
       ├─ codex  → EzagentPluginCodex.BridgeAdapter # WS push "codex_turn"  → codex subprocess
       └─ curl   → (curl adapter)                   # in-process HTTP call
```

**How claude-code's MCP-subprocess fits as a per-flavor specificity UNDER the
unified agent receive (the constraint, satisfied):**

1. The DELIVERY of a chat message to a cc agent already rides the cc flavor
   adapter (`BridgeAdapter.deliver/2` push `to_claude`) — this needs no
   special-casing; it is just one adapter among three.
2. The ORCHESTRATOR MCP surface (the 7 tools) is the part currently
   special-cased at the SESSION level (it lives in `ezagent_domain_instance_message`,
   §1.6). The proposal **moves it UNDER the cc flavor adapter as a cc-flavor
   capability**, not a session capability:
   - `McpChannel` / `McpSocket` / `McpServer` / `McpRegistry` / `orchestrator_bridge.py`
     / `CcOrchestratorSeed` migrate OUT of the session domain INTO the cc plugin
     (or a small cc-owned "orchestrator transport" module that the cc flavor
     adapter declares).
   - The cc flavor adapter (which already owns the `--mcp-config` wiring via the
     cc Template Class, `cc_agent/spawn.ex:459`) is the natural owner of the
     orchestrator MCP server: it is a SECOND MCP server linked into the same
     `claude` subprocess at launch.
   - The session domain then knows only "this agent member can be sent
     `chat.receive`"; it does NOT know about MCP, stdio bridges, or orchestrator
     tools. The orchestrator tools become "things a cc agent can DO" (a cc-flavor
     outbound capability), symmetric to the cc `reply` tool — both are MCP tools
     the cc subprocess exposes and the cc adapter services.

This is the key claim: **claude-code's MCP-subprocess is a property of the cc
FLAVOR, reachable only beneath `Agent.receive`'s flavor dispatch — never a thing
the session substrate models directly.** codex/curl adapters simply don't
declare an orchestrator-MCP transport; the unified `Agent.receive` is identical
for all three, and the divergence is fully contained in the per-flavor adapter.

**curl reconciliation (the real fork):** today curl is a separate Kind
(`Entity.CurlAgent`) with its OWN `:receive` Behavior — it bypasses
`AgentBridge` entirely (§1.5). To fit the unified shape, curl should become a
flavor adapter under the SAME `Agent.receive` (a `curl` `AgentBridge.Adapter`
whose `deliver/2` runs the in-process HTTP call rather than pushing to a
subprocess), OR `AgentBridge` grows an explicit "in-process synchronous flavor"
adapter mode. Either way the goal is: ONE `Agent.receive`, three adapters, no
parallel curl Kind. This is the largest piece of real work and the source of
OQ-1.

### 2.4 3-domain placement + dependency directions

```
   im (ingestion + outbound transport)
        │  calls Session.send/3 only — no agent symbol in scope
        ▼
   session (Session Kind, Chat, Routing/RuleStore, session-mgmt tools)
        │  Agent.receive → AgentBridge.deliver  (depends on agent-transport)
        ▼
   agent (Agent Kind, AgentBridge + Adapter behaviour, flavor adapters live in plugins)
```

- **im → session → agent**, acyclic. im depends on session's `Session.send/3`
  facade; session depends on the agent-transport (AgentBridge) contract; agent
  (and its flavor adapters) depend DOWN on core + the adapter behaviour, and
  register UP at boot via the plugin contract. No cycle: an agent's REPLY does
  NOT create an `agent → session` compile dependency — it goes through
  `Ezagent.Invocation.dispatch` to a `session://?action=chat.send` URI (runtime
  dispatch, the Invariant-#1 "dispatch is the only path", `bridge_adapter.ex:160`),
  which is dependency-free.
- **Where Chat lives:** Chat is the SESSION substrate's core Behavior — it stays
  in **domain.session**. Its `:send` (fan-out) is session-owned. Its `:receive`
  registrations split: `User.receive` is a session/identity concern;
  `Agent.receive` is the seam INTO the agent domain (it calls the agent-transport
  facade). Cleanest cut: `session.send` + `User.receive` in domain.session;
  `Agent.receive` + AgentBridge + Adapter behaviour in domain.agent; the routing
  layer (Resolver/RuleStore) in domain.session.
- **AgentBridge today already sits at the right altitude** (depends only on core,
  §1.6) — it is the natural home of the "agent transport" the agent domain owns.
- **The orchestrator MCP move (§2.3) FIXES the §1.6 anomaly:** it relocates a
  cc-flavor concern OUT of the session domain INTO the cc plugin, removing the
  session domain's knowledge of MCP/stdio/orchestrator-tools.

### 2.5 What this de-special-cases (summary)

| Today | After |
|---|---|
| im open-codes a `chat.send` dispatch to a session URI (convention) | im calls `Session.send/3`; cannot address an agent (structural) |
| One `Chat.handle_receive` with `case ctx[:kind_module]` (User/Agent) | Two registrations of one `:receive` verb — `User.receive`, `Agent.receive` |
| curl is a parallel Kind+Behavior bypassing AgentBridge | curl is one `AgentBridge.Adapter` among three under `Agent.receive` |
| Orchestrator MCP (McpChannel/Server/bridge) lives in the SESSION domain | Orchestrator MCP is a cc-FLAVOR capability under the cc adapter |
| cc MCP-subprocess implicitly special at session level | cc MCP-subprocess is a per-flavor specificity beneath `Agent.receive` |

---

## 3. HONEST FRICTION — where the current code resists unification

1. **curl is the genuine outlier.** cc+codex are already unified beneath
   `AgentBridge.Adapter`; curl is a separate Kind with its own `:receive`. Folding
   it in is real work (a new in-process adapter mode, or migrating
   `Entity.CurlAgent` to `Entity.Agent` + a curl flavor). Until done, the
   "one `Agent.receive`, N adapters" claim has an asterisk.

2. **`AgentBridge.Adapter` is WS/Channel-shaped.** Its callbacks
   (`handle_client_event/3`, `join_info/2`, `socket_path/0`,
   `channel_topic_prefix/0` — `adapter.ex:12-20`) assume a Phoenix Channel
   sidecar. An in-process flavor (curl) has no socket/channel, so either those
   callbacks become optional (some already are, `adapter.ex:20`) or the adapter
   contract is widened to cover "subprocess-WS" vs "in-process-sync" transport
   classes. The contract is not transport-neutral today.

3. **The orchestrator MCP move crosses a tier boundary cleanly but is invasive.**
   `McpServer.handle_tool_call/3` runs the 7 SESSION-orchestration tools
   (`add_agent_slot`, `write_matcher`, ...) — these MUTATE session/routing state.
   Moving the TRANSPORT (channel/socket/python bridge) to the cc plugin is clean;
   but the TOOLS themselves are session-domain operations the cc agent INVOKES.
   So the split is: orchestrator-MCP *transport* → cc plugin (flavor adapter
   capability); orchestrator *tools* (the operations) → stay in domain.session,
   invoked via dispatch. The cc adapter forwards `tools/call` INTO the session
   domain's tool handlers. This keeps tier discipline but means the cc adapter
   has a session-facing call edge for orchestrator tools (acceptable: it is
   runtime dispatch, not a compile dep — same shape as `reply`).

4. **Two cc subprocess MCP servers, one constraint, different lifetimes.** The
   cc CHAT bridge and the orchestrator MCP bridge are independent subprocesses
   with independent readiness gates (`LiveJoinRegistry`,
   `mcp_channel.ex:60-110`). The unified design treats both as cc-flavor MCP
   capabilities, but they are NOT one transport — the design must keep them
   independently evolvable (the current separate-Channel rationale,
   `mcp_channel.ex:46-53`, is sound and should survive the move).

5. **`Session.send/3` mode override.** im needs `:call` (surface cap-denial),
   agent-reply/LV use `:cast`. The named facade must keep mode a parameter, not
   bake in `:cast`, or it regresses the "no silent drop" invariant
   (`inbound_dispatcher.ex:36-44`).

---

## 4. OPEN QUESTIONS FOR ALLEN (genuine forks — not invented answers)

> **OQ-1 — curl unification: in-process adapter vs flavor migration?**
> curl today is `Entity.CurlAgent` with its own `:receive` Behavior, fully
> in-process (no bridge/subprocess). To fit `session.send |> entity_type.receive`
> with ONE `Agent.receive`, do we (a) add an "in-process synchronous" adapter
> mode to `AgentBridge.Adapter` and register curl as a flavor adapter, or (b)
> migrate `Entity.CurlAgent` into `Entity.Agent` with a `curl` flavor? (a) is
> smaller but widens the adapter contract to non-socket transports; (b) is
> cleaner long-term but a bigger Kind migration + snapshot change. Which?

> **OQ-2 — orchestrator-MCP relocation: full move, or transport-only?**
> The orchestrator MCP transport (`McpChannel/McpSocket/McpRegistry/orchestrator_bridge.py/CcOrchestratorSeed`)
> lives in domain.session today (the §1.6 anomaly). Proposal moves the TRANSPORT
> to the cc plugin (a cc-flavor capability) while the 7 TOOLS' operations stay in
> domain.session (invoked via dispatch). Do you want (a) transport-only move
> (tools stay session-domain, cc adapter forwards `tools/call` in), or (b) the
> whole orchestrator surface (transport + tool handlers) into the cc plugin? (b)
> would put session-mutation logic in a plugin — likely violates the three-tier
> rule, but I want your call before assuming (a).

> **OQ-3 — does `Session.send/3` become a real Behavior action, or a domain facade?**
> "im only talks to the session" can be enforced two ways: (a) a thin domain
> facade module `Session.send/3` over the existing `Chat.:send` dispatch (rename
> + boundary guard, minimal), or (b) a NEW first-class Session Kind action
> distinct from `Chat.:send`, with Chat.:send becoming session-internal. (b) is
> more "honest" (the public entry differs from the internal fan-out verb) but
> adds an action + caps surface. Which altitude?

> **OQ-4 — should `User.receive` and `Agent.receive` be SEPARATE Behaviors or
> stay one Chat Behavior with two registrations?**
> The de-special-casing in §2.2 can be (a) literally two Behavior modules
> (`Behavior.UserReceive`, `Behavior.AgentReceive`) each registered for `:receive`
> on its Kind, or (b) keep one `Behavior.Chat` that registers `:receive` on both
> Kinds and keeps the internal `case` (status quo). (a) matches the
> "entity_type.receive" goal most literally but fragments Chat; (b) is less code
> churn but keeps the branch. Do you want the literal per-entity-type split, or
> is the single-Behavior-two-registrations form "unified enough"?

> **OQ-5 — `AgentBridge.Adapter` contract: widen to transport-neutral now, or
> keep WS-shaped and special-case curl?**
> Tied to OQ-1(a). If curl becomes an adapter, the adapter behaviour's
> WS/Channel-specific callbacks (`socket_path/0`, `channel_topic_prefix/0`,
> `handle_client_event/3`) don't apply to an in-process flavor. Do we make the
> adapter contract explicitly two-shaped (subprocess-WS vs in-process-sync), or
> defer and keep curl on its own path for now (accepting the asterisk in §3.1)?

> **OQ-6 — naming: is `entity_type.receive` the right ubiquitous-language term,
> or do you want `member.receive` / `recipient.receive`?**
> The goal text says `entity_type.receive`. The codebase says "member" (session
> members) and "recipient" (routing). Confirm the canonical noun before it lands
> in action names + GLOSSARY (these are expensive to rename later per the
> snapshot-key + call-site coupling, cf. `chat.ex:101-110`).

---

## 5. Bottom line

- **Goal #1 (im → session only):** ~80% true by convention in the Feishu path;
  make it STRUCTURAL via a named `Session.send/3` facade (OQ-3).
- **Goal #2 + #3 (session forwards via unified `entity_type.receive`):** the
  pattern ALREADY EXISTS in skeleton — `Chat.:send` fans out, `Chat.:receive`
  branches User/Agent. Promote the branch into per-entity-type registrations.
- **The cc MCP-subprocess constraint:** satisfiable WITHOUT a session-level
  special case — it becomes a cc-FLAVOR capability beneath `Agent.receive`'s
  flavor dispatch (move the orchestrator MCP transport into the cc plugin,
  fixing the §1.6 anomaly).
- **Dependency direction:** im → session → agent, acyclic; Chat stays in
  domain.session; AgentBridge is the agent-transport seam (already at the right
  altitude).
- **Biggest real work / risk:** curl (a parallel Kind, not a flavor adapter) and
  the adapter contract's WS-shape (OQ-1, OQ-5).
