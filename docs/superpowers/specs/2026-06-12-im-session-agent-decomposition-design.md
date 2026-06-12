# im / session / agent 3-Domain Decomposition + Unified Agent–Session Transport — DESIGN SPEC

**Status:** DESIGN SPEC (a design doc; not a plan, not implemented)
**Date:** 2026-06-12
**Branch:** `research/unified-agent-session-transport` (off origin/main @ #734)
**Author:** Claude (Opus 4.8, ezagent-developer + elixir-phoenix-helper loaded)
**Builds on:** `docs/superpowers/specs/2026-06-12-unified-agent-session-transport-research.md` (the research; current-state map §1, proposed design §2) and `docs/architecture/communication-overview.md` (durable current-state reference, incl. the Claude-Code dev-channels loader).
**Supersedes the open framing of:** that research's §4 OQ-1..OQ-7 — Allen has DECIDED them; they are baked in below as the design.

> This is the LARGE refactor design that (a) splits today's `ezagent_domain_instance_message` "session-ish" domain into **im / session / agent**, (b) unifies the agent transport behind `session.send |> entity.receive`, and (c) folds curl-as-flavor and relocates the orchestrator-MCP transport. It SUBSUMES the old P5-A/P5-1/P5-2/P5-3 Session-collapse work (the unified Session Kind it produces is the chokepoint this design's `session.send` action lives on) and ADDS the domain split + transport unification.

---

## Revision (codex round-1 + OQ decisions)

**Rev 2 — 2026-06-12.** This revision closes a codex adversarial review (round 1) and bakes in the four open questions Allen decided (O-1..O-4 below). The earlier "OPEN QUESTIONS" framing is removed; those points are now stated as design.

### Decided open questions (now design, not questions)

- **O-1 — Domain name is `session` (`domain.session`), NOT `socialware`.** socialware is ONE Template flavor over the session substrate; naming the domain after one flavor would invert the generalization the P5 collapse achieves. Used throughout. §5 retained as the rationale record (no longer a question).
- **O-2 — curl flavor mechanism + migration shape.** The curl flavor is a **stored slice field** on the unified Agent slice (NOT a name-segment prefix). The curl snapshot migration is a **reversible `kind_type` alias** (`curl_agent` aliases to the unified Agent Kind, retained through a rollback window), NOT a destructive row rewrite. §3.5 / §6.1 spec it concretely.
- **O-3 — ONE LINE (one coherent effort).** The P5 collapse and the domain split ship as one effort — BUT the codex ordering fix below decouples them at the *merge-gate* level: the transport-unification PRs do not hard-depend on the P5 collapse completing. P5 collapse is a parallel track with its own DEFER valve. See §4.1.
- **O-4 — Orchestrator's 4 delegated caps are assembled session-side at the dispatch chokepoint.** A named session action reconstructs them; the cc transport carries only the orchestrator's caller URI, never ambient authority. Pinned in §3.4 + HIGH-3 below.

### Codex findings closed (REVISE blockers)

| Finding | Where closed | One-line resolution |
|---|---|---|
| **HIGH-1** curl is STATEFUL, the adapter is not | §3.5, §3.3 | curl STATE stays a real **Behavior on the unified Agent** (`:curl_agent` slice + `reset_conversation`/`configure` actions, composed only for the curl flavor); the **adapter is ONLY the HTTP transport** in `:in_process_sync`. The adapter delivers; the behavior owns state/effects via normal `{:set,…}`. |
| **HIGH-2** snapshot cold-load break (`agent_module_resolver.ex:106`) | §6.1, §3.5, PR-7 | Reversible `kind_type: curl_agent → Entity.Agent` **alias** retained through a rollback window; flavor slice set to `curl`; `:curl_agent` cap-axis subjects migrated to `:agent`; conversation/credential/`:creator_uri` slices preserved. `Entity.CurlAgent` deleted ONLY after alias+migration land and prove reversible. |
| **HIGH-3** session→MCP-transport compile edge (`orchestrator.ex:280,767`) | §3.4, §3.6 (new) | A session-owned neutral **`Ezagent.Session.OrchestratorReadinessPort`** (behaviour) the cc plugin REGISTERS an impl into at boot; session calls the port, never the cc module. Introduced in a NEW PR-8a BEFORE the transport relocation. The 4 delegated caps are reconstructed session-side at the dispatch chokepoint (O-4). |
| **MED-1** incomplete `chat.send` sweep | §3.1.1 (new), PR-1 | Full external/plugin caller list enumerated; PR-1 adds `session.send` as the public entry and migrates ALL of them; `chat.send` stays PUBLIC until the sweep completes, only THEN becomes session-internal. "`chat.send` has no remaining external caller" is a PR gate. |
| **MED-2** adapter widen leaks past `deliver/2` | §3.3 | PR-0 also (a) validates `transport_class/0` at Channel join (rejects non-`:subprocess_ws` from the WS path) and (b) branches `deliver_ensuring`/`deliver_ensuring_with_flavor` for `:in_process_sync` (no channel pid, no Registry-lookup/`ensure_ready` readiness gate) — not only the low-level `deliver/2`. Per-class required-callback contract spec'd. |
| **ORDERING** decouple P5 from blocking transport | §4.1 | Re-ordered/annotated PR list: transport-unification PRs (PR-0,1,2,6,7,8a,8) form the load-bearing line and do NOT hard-depend on the P5 collapse (PR-3,4,5). P5 is a parallel track with a DEFER valve. PR-9 (physical split) stays LAST, gated by acyclic arch-fitness. |
| **LOW** (note, don't block) | §9 (new) | IM still resolves agent mentions directly (`mention_parser.ex:134`) — noted as a follow-up to route behind a session query facade. |

---

## 0. Decisions baked in (formerly the research §4 open questions)

These were genuine forks in the research. Allen decided them; this spec states them as the design, not as questions.

| Ref | Decision (Allen) |
|---|---|
| **OQ-1 curl** | Merge `Entity.CurlAgent` INTO `Entity.Agent` as a **`curl` flavor**, NOT a separate Kind. **Decomposition (codex HIGH-1):** curl's STATE stays a real **Behavior on the unified Agent** (the `:curl_agent` slice + `reset_conversation`/`configure` public actions, composed only for the curl flavor via the per-instance behavior set); the curl **adapter is ONLY the HTTP transport** in `:in_process_sync` mode. Bigger Kind migration + snapshot change — designed in §3.5/§6.1. |
| **OQ-2 orchestrator MCP** | Move ONLY the **transport** (`McpChannel`/`McpSocket`/`McpRegistry`/`CcOrchestratorSeed`/`orchestrator_bridge.py`) to the **cc plugin** as a cc-flavor adapter capability. The **7 tools' operations STAY in the session domain**, invoked via `Invocation.dispatch`. No session-mutation logic moves into a plugin. **The session→cc compile edge (codex HIGH-3) is broken by a session-owned `OrchestratorReadinessPort` (§3.6).** |
| **OQ-3 session.send** | `session.send` is a **first-class action on the unified Session Kind** (the one Kind the P5 collapse produces) — the single entry IM uses. `chat.send` becomes session-INTERNAL beneath it (the fan-out verb) **AFTER the full external-caller sweep completes (codex MED-1, §3.1.1)**. |
| **OQ-4 / OQ-7 receive** | **Two separate Behaviors**: `User.receive` (inbox / cursor-ring slice) and `Agent.receive` (deliver to the live agent via AgentBridge), each registered for the `:receive` action on its own Kind. They are genuinely different (passive inbox vs active process delivery) and are NOT merged. Canonical action names: `user.receive` / `agent.receive`. |
| **OQ-5 adapter contract** | Widen `AgentBridge.Adapter` to **transport-neutral NOW** — it must support both the subprocess-WS flavors (cc / codex) AND an in-process synchronous flavor (curl). The WS-specific callbacks are no longer assumed by the contract. **The widen reaches the `deliver_ensuring*` + Channel-join layers, not only `deliver/2` (codex MED-2, §3.3).** |
| **OQ-6 naming term** | The ubiquitous-language verb is **`<entity>.receive`** materialized as `user.receive` / `agent.receive` (per OQ-4). |
| **cc MCP-subprocess** | The claude-code MCP-subprocess (esr-bridge chat bridge + orchestrator bridge) is a **cc-flavor adapter UNDER `Agent.receive`**, loaded via `--dangerously-load-development-channels` — NOT a session-level special case. |

**All four formerly-open questions are now DECIDED** (O-1 domain name = `session`; O-2 curl flavor = stored slice field + reversible `kind_type` alias; O-3 one effort, P5 decoupled at the merge gate; O-4 the 4 delegated caps assembled session-side at the dispatch chokepoint). See the Revision section above and §5/§6.1.

---

## 1. Goal + the 3-domain target

### 1.1 Goal

Make the communication topology STRUCTURAL, not conventional:

1. **im talks ONLY to the session.** No symbol in the im domain can address an agent. Today this is ~80% true by convention (the Feishu path only ever dispatches `session://` URIs — research §1.1) but nothing structurally prevents an IM plugin from dispatching `entity://agent/...?action=agent.receive` directly.
2. **The session forwards** each message to its member entities through ONE entity-communication pattern: `session.send |> <entity>.receive`.
3. **The unified transport lives in the session/agent seam** — `session.send` (session-owned) fans out via the (UNCHANGED) routing layer to `user.receive` (session) / `agent.receive` (agent), and `agent.receive` hands DOWN to a transport-neutral `AgentBridge.deliver`, which resolves flavor → adapter. All flavor-specificity (cc MCP-subprocess, codex bridge, curl in-process HTTP) lives ONLY in the per-flavor adapter, beneath `agent.receive`.

### 1.2 The 3-domain target

| Domain | Owns |
|---|---|
| **im** | External IM ingestion (Feishu/Slack webhook + WS) and outbound transport (channel-server / gateway / sidecar). The inbound dispatcher that converts an external event into a session message. Calls **`Session.send`** and nothing else session-internal; no agent symbol in scope. |
| **session** | The **unified Session Kind** (the P5-collapse union), **Chat** (now the session-internal fan-out, beneath `session.send`), the **routing layer** (Resolver / RuleStore / mention-gating), **session-management logic** (session_creator, the orchestrator **tools' operations** — `add_managed_member` / `define_rule_set_rule` / `update_template` / …), the `session.send` first-class action, and **`User.receive`** (inbox / cursor-ring). |
| **agent** | The **Agent Kind** (now incl. the **curl flavor** — `Entity.CurlAgent` folded in), the **transport-neutral `AgentBridge`** + `Adapter` behaviour, and **`Agent.receive`** (the seam from session into the agent transport). Flavor adapters (cc / codex / curl) live in the plugins and register UP at boot. |

### 1.3 Dependency directions (im → session → agent, acyclic — with evidence)

```
   im (ingestion + outbound transport)
        │  calls Session.send/3 only — no agent symbol in scope (structural)
        ▼
   session (unified Session Kind, Chat-internal fan-out, Routing/RuleStore,
            session-mgmt logic incl. orchestrator tool OPS, User.receive,
            the session.send action)
        │  Agent.receive → AgentBridge.deliver  (compile-dep on agent transport)
        ▼
   agent (Agent Kind incl. curl flavor, transport-neutral AgentBridge + Adapter,
          Agent.receive; flavor adapters live in plugins, register UP at boot)
```

- **im → session** is a compile dependency on the `Session.send/3` facade only. The im domain has no agent symbol; goal #1 becomes enforced by the dependency graph, not convention.
- **session → agent** is a compile dependency on the AgentBridge transport contract (`agent.receive` calls `AgentBridge.deliver`). `ezagent_domain_agent_bridge` today already depends ONLY on `ezagent_core` (research §1.6, `apps/ezagent_domain_agent_bridge/mix.exs:33`) — a clean leaf, the right altitude to host the "agent transport."
- **NO cycle from an agent reply.** An agent's reply does NOT create an `agent → session` compile edge: it goes through `Ezagent.Invocation.dispatch` to a `session://?action=session.send` URI (runtime dispatch — Invariant #1 "dispatch is the only path"; today `bridge_adapter.ex:160` already does this to `chat.send`). Runtime dispatch is dependency-free.
- **The §1.6 anomaly is FIXED by construction:** the orchestrator-MCP *transport* leaves the session domain for the cc plugin (OQ-2), so the session domain no longer knows about MCP / stdio / orchestrator-bridge subprocesses. The orchestrator *tool operations* stay in session as plain dispatch-invoked session logic.

---

## 2. What moves where (module → target-domain mapping)

Concrete mapping of every relevant current module (from research §1 + communication-overview) to its target domain. "Stays" = no domain move (may still be split/renamed). All current paths are under `apps/ezagent_domain_instance_message/` unless noted.

### 2.1 → domain.session

| Current module / file | Target | Change |
|---|---|---|
| `Ezagent.Entity.Session` (`lib/ezagent/entity/session.ex`) | session | Becomes the **unified Session Kind** (P5-1 union of Chat + Surface + Turn + ConfigUpdate + Publisher + …); `session.send` action added to it (OQ-3). |
| `Ezagent.Entity.SocialwareSession` | session | Folded into the unified Session Kind by the P5 collapse; module retired (P5-3). |
| `Ezagent.Behavior.Chat` (`lib/ezagent/behavior/chat.ex`) | session | Stays in session. `:send` is **renamed-internal** — the public entry is `session.send`; `chat.send` (the fan-out) becomes the session-internal verb beneath it. Its `:receive` registrations are split out (see §2.1 receive rows). |
| `Ezagent.Routing.Resolver` / `RuleStore` / `MentionRouting` / `RoutingRegistry` / `EzagentDomainInstanceMessage.DefaultRules` | session | **UNCHANGED, reused wholesale** — "WHICH members receive." Default rule `{:always} → ["$session_users", "$mentions"]` (`default_rules.ex:90`) unchanged. |
| `Ezagent.Behavior.Chat.handle_receive` **User branch** (`chat.ex:561-604`) | session | Extracted into a first-class **`Ezagent.Behavior.User.Receive`** registered for `:receive` on `Entity.User` → action `user.receive` (OQ-4). Inbox / `:last_received` + cursor-ring slice; SliceChange hook emits the notification. |
| `EzagentDomainInstanceMessage.SessionCreator` (`session_creator.ex` + `session_creator/`) | session | Stays — session-management logic. |
| `Ezagent.Entity.SessionTemplate` / `Ezagent.Template.GenericSession` | session | Stay — Templates select the per-instance behavior set on the unified Kind (P5). |
| `Ezagent.Orchestrator.Tools` (`orchestrator/tools.ex` + `tools/`: `member_template.ex`, `templates.ex`, `tool_catalog.ex`) — the 7 tool OPERATIONS (`add_managed_member` / `define_rule_set_rule` / `update_template` / `update_member_template` / `remove_member` / `define_legend` / `define_prompt_template` …) | session | **Stay in session** (OQ-2). These MUTATE session/routing state; they are session-domain operations. Invoked via `Invocation.dispatch` from the cc adapter's `tools/call` forward (§3.4). |
| `Ezagent.Behavior.OrchestratorAdmin` (`lib/ezagent/behavior/orchestrator_admin.ex`) | session | Stays — the session-side Behavior surface the orchestrator tool ops dispatch into. |
| `entity/session/` (slice impls), `behavior/publisher/session_impl.ex` | session | Stay with the Session Kind. |

### 2.2 → domain.agent

| Current module / file | Target | Change |
|---|---|---|
| `Ezagent.Entity.Agent` (`lib/ezagent/entity/agent.ex`) | agent | Moves to the agent domain. Gains **curl** as a flavor (OQ-1) — see §2.3 / §3.2. |
| `Ezagent.Entity.AgentTemplate` (`agent_template.ex`) | agent | Moves with the Agent Kind. Gains a `curl` template flavor. |
| `Ezagent.Behavior.Chat.handle_receive` **Agent branch** (`chat.ex:606-611`) → `Delivery.deliver_agent_receive/2` (`chat/delivery.ex:207-276`) | agent | Extracted into a first-class **`Ezagent.Behavior.Agent.Receive`** registered for `:receive` on `Entity.Agent` → action `agent.receive` (OQ-4). Builds the flavor-neutral `AgentBridge.Payload`, calls `AgentBridge.deliver`. |
| `Ezagent.AgentBridge` + `AgentBridge.Adapter` + `AdapterRegistry` + `Payload` + `Channel` + `Socket` + `Registry` + `TokenStore` + `AttachmentNormalizer` (`apps/ezagent_domain_agent_bridge/**`) | agent | **Already a clean leaf domain** (`mix.exs:33` → core only). Becomes the agent domain's transport. `Adapter` contract **widened to transport-neutral** (OQ-5, §3.3). |

### 2.3 → cc plugin (flavor adapter / cc-flavor capability)

| Current module / file | Target | Change |
|---|---|---|
| `Ezagent.Orchestrator.McpChannel` / `McpSocket` / `McpRegistry` / `LiveJoinRegistry` / `Health` (`orchestrator/`) | **cc plugin** | The orchestrator-MCP **transport** relocates OUT of the session domain INTO `ezagent_plugin_cc` as a cc-flavor capability (OQ-2). |
| `Ezagent.Orchestrator.CcOrchestratorSeed` | **cc plugin** | The orchestrator MCP-config seeding moves to cc (it already owns the `--mcp-config` wiring via `cc_agent/spawn.ex:459`). |
| `priv/orchestrator_bridge.py` | **cc plugin** | The second MCP-server subprocess relocates to `apps/ezagent_plugin_cc/priv/`. |
| `Ezagent.Orchestrator.McpServer` (`mcp_server.ex` + `mcp_server/tool_catalog.ex`) | **split** | The MCP **request plumbing** (`tools/list` schema, `tools/call` DECODE) → cc plugin (transport). The **tool dispatch target + the caps-context construction** stay session: `McpServer.handle_tool_call/3` becomes "forward `tools/call` INTO the session domain via `Invocation.dispatch` to a named session action that reconstructs the 4 delegated caps session-side (O-4) then runs the `Orchestrator.Tools` op" (OQ-2). The cc transport carries only the orchestrator's caller URI, never ambient authority. |
| **NEW: `Ezagent.Session.OrchestratorReadinessPort`** (behaviour) | session (defined) / cc (impl registered at boot) | **Codex HIGH-3.** Today `orchestrator.ex:280,767` calls `Orchestrator.McpChannel.lifecycle_topic/0`, `LiveJoinRegistry.joined?/1`, `McpRegistry.register/…` directly. Relocating those modules to cc would create a session→cc compile edge (breaks acyclic `im→session→agent`). Instead, session OWNS a neutral readiness/context PORT; the cc plugin registers an implementation into it at boot; session calls the port, never the cc module. Introduced in PR-8a BEFORE the transport relocation (§3.6). |
| `EzagentPluginCc.BridgeAdapter` (`bridge_adapter.ex`) + `python/ezagent_mcp_bridge.py` (esr-bridge chat bridge) + `McpConfigWriter` | cc plugin | **Stay in cc.** Already the cc flavor adapter. Becomes one of three transport-neutral adapters under `agent.receive`. |

### 2.4 → codex plugin (unchanged location)

| Current | Target | Change |
|---|---|---|
| `EzagentPluginCodex.BridgeAdapter` + `priv/python/ezagent_codex_bridge.py` | codex plugin | **Stays.** One of three adapters under `agent.receive`; no orchestrator-MCP surface. |

### 2.5 curl plugin → folded into the Agent Kind + a curl adapter

| Current | Target | Change |
|---|---|---|
| `Ezagent.Entity.CurlAgent` (`apps/ezagent_plugin_curl_agent/lib/ezagent/entity/curl_agent.ex`, `type_name: :curl_agent`) | **DELETED (after migration)** | Folded into `Entity.Agent` as the `curl` flavor (OQ-1). Deleted ONLY in PR-7 AFTER the reversible `kind_type` alias + snapshot migration land and prove reversible (codex HIGH-2). |
| `Ezagent.Behavior.CurlAgent` (`apps/ezagent_plugin_curl_agent/lib/ezagent/behavior/curl_agent.ex`) — the STATE + actions: `:curl_agent` slice, `handle_reset_conversation/2`, `handle_configure/2`, the conversation/`:last_error`/`:last_tokens` `{:set,…}` effects | **STAYS A BEHAVIOR** (on the unified Agent) | **Codex HIGH-1.** curl is STATEFUL; the adapter is not. This Behavior is REPARENTED onto `Entity.Agent` and composed into the per-instance behavior set ONLY for the `curl` flavor. It keeps owning the `:curl_agent` slice + the PUBLIC `reset_conversation` / `configure` actions + the durable `{:set, :conversation, …}` / `{:set, :last_error, …}` / `{:set, :last_tokens, …}` effects. What it SHEDS is the in-process HTTP round-trip (→ the curl adapter, next row). It no longer registers its own `:receive`. |
| `Ezagent.Behavior.CurlAgent.do_receive_effects/2` HTTP round-trip (`curl_agent.ex` `run_completion/6` + `EzagentPluginCurlAgent.ApiClient`) | **curl adapter (transport only)** | The HTTP call ALONE becomes the `curl` **`AgentBridge.Adapter`** (`transport_class :in_process_sync`, §3.3). The adapter does the HTTP round-trip and RETURNS the result to `agent.receive`; the resulting state mutation (append turn, set tokens/error) flows through the curl **Behavior's** normal `{:set,…}` effects — NOT the adapter return value. The adapter never persists. |
| `Ezagent.Template.CurlAgent` | curl plugin | Becomes a **curl agent Template** (a flavor template) over the unified Agent Kind, not a separate Kind's template. Selects the curl Behavior set (incl. the reparented curl-state Behavior) on the unified Kind. |
| `EzagentPluginCurlAgent.ApiClient` | curl plugin | Stays — the curl adapter's HTTP client. |
| `Behavior.ApiKeys` (already on both `Entity.Agent` and `CurlAgent`) | agent | Already on the Agent Kind (`entity/agent.ex` behaviors) — curl's `:api_keys` need is satisfied by the unified Agent Kind without duplication. |

### 2.6 → domain.im

| Current | Target | Change |
|---|---|---|
| `EzagentPluginFeishu.WebhookPlug` / `WsClient` | im | The ingestion transports — webhook + WS long-connect. |
| `EzagentPluginFeishu.InboundDispatcher` (`inbound_dispatcher.ex:58`) | im | The convert-external-event-into-session-message dispatcher. **Change:** its `dispatch_to_session/5` (`:248`) stops open-coding `URI.with_action(session_uri, :chat, :send)` (`:286`) and instead calls **`Session.send/3`** (the named facade / action — §3.1). After this, the im domain has no `chat`/agent symbol. |
| `EzagentPluginFeishu.{SenderResolver, MentionParser, InboundChatLookup}` | im | Stay in the im plugin (ingestion-side resolution). `InboundChatLookup` keeps reading the generic `external_mirror_bindings` table. |
| outbound transport (channel-server / gateway / sidecar) | im | The im domain's outbound side. |

---

## 3. The unified transport (as designed)

### 3.1 `session.send` — first-class Session action (the ONE inbound point)

`session.send` is a **first-class action on the unified Session Kind** (OQ-3), not merely a facade. It is the single entry IM uses; `chat.send` becomes session-internal.

```
Session.send(session_uri, %Message{}, ctx)         # FIRST-CLASS action on the unified Session Kind
  └─ dispatch <session_uri>?action=session.send     # public entry
       └─ (session-internal) chat.send fan-out       # the internal verb, no longer the public surface
```

- **Behavior:** a `:send` action registered on the unified Session Kind. Its handler performs (or delegates to Chat for) persist + route + fan-out. `chat.send` is demoted to the internal fan-out step invoked beneath `session.send` — callers outside the session domain can no longer reach it.
- **Mode parameter preserved (Decision #134, research §3.5):** `Session.send/3` keeps `mode` a parameter (`:call` for IM so cap-denial surfaces to the human — `inbound_dispatcher.ex:36-44`; `:cast`/`:ignore` for agent-reply + LV). Do NOT bake in `:cast` or it regresses the "no silent drop at user-facing surfaces" invariant (#9).
- **Caps surface:** `session.send` carries its own required-caps (Invariant #19 — caps normalize at the chokepoint; #18-style declared reads). IM's caller URI + caps flow through unchanged from `SenderResolver`.
- **Why first-class, not a thin facade:** the public entry differs semantically from the internal fan-out verb; modeling it as a distinct action makes "im → session only" enforceable by the action surface + dependency graph, and lets the caps/authz live on the public entry rather than on the internal fan-out.

### 3.1.1 The `chat.send` external-caller sweep (codex MED-1)

`chat.send` (`URI.with_action(session_uri, :chat, :send)`) has external/plugin callers BEYOND the IM inbound dispatcher. Demoting it to session-internal in one step would silently break them. PR-1 adds `session.send` as the public entry and migrates EVERY external caller to it; `chat.send` stays PUBLIC until the sweep is complete, and only THEN becomes session-internal (its public `:send` action registration is removed).

**Full external/plugin caller list (verified against the tree, rev 2):**

| Caller | Location | Nature |
|---|---|---|
| Feishu inbound dispatcher | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex:286` | IM ingestion → session (the headline path; §2.6). |
| Cross-session fan-out | `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat/delivery.ex:72` (`dispatch_cross_session_call/2`) | session → other session re-entry; becomes the session-internal `session.send` re-entry (already in-domain, but the `:chat,:send` action ref must move with the rename). |
| cc reply | `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/bridge_adapter.ex:157` | agent reply → session. |
| codex reply | `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/bridge_adapter.ex:92` | agent reply → session. |
| curl reply | `apps/ezagent_plugin_curl_agent/lib/ezagent/behavior/curl_agent.ex:307` | agent reply → session (this caller LIVES IN the curl-state Behavior that the agent retains — HIGH-1). |
| echo reply | `apps/ezagent_plugin_echo/lib/ezagent/behavior/echo.ex:175` | agent reply → session. |
| np reply | `apps/ezagent_plugin_np/lib/ezagent/behavior/np_agent.ex:315` | agent reply → session. |
| LV compose | `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin/compose.ex:99` | UI send → session (`:cast`/`:ignore` mode). |

(Also: operator tooling `ezagent.stress.ex:371` and `audit.ex:179` build the `chat.send` URI as a string — migrate these to `session.send` too; the `uri.ex` / `capability.ex` / migration-comment doctest strings are documentation and update with the rename.)

**Migration mode discipline:** the agent-reply callers (cc/codex/curl/echo/np) and LV use `:cast`/`:ignore`; the IM dispatcher uses `:call` so cap-denial surfaces (Invariant #9). `Session.send/3` preserves `mode` (§3.1), so each caller keeps its existing mode when it switches to `session.send`.

**PR gate (codex MED-1):** an arch/grep invariant test asserts **`chat.send` has NO remaining external caller** — no `with_action(_, :chat, :send)` and no `?action=chat.send` literal outside the session domain. Only after this gate is green does PR-1 remove `chat.send` from the public action surface (demote to internal fan-out).

### 3.2 The routing fan-out (UNCHANGED, reused)

Beneath `session.send`, the session-internal fan-out is exactly today's `Chat.handle_send/2` machinery (research §1.2), reused wholesale:

```
session.send handler  (unified Session Kind, domain.session)
  ├─ persist            (MessageStore.write/2,  chat.ex:444)
  ├─ resolve recipients (Routing.Resolver.resolve_with_ctx/4, chat.ex:483 — SINGLE source of truth)
  │     default rule {:always} → ["$session_users", "$mentions"]  (default_rules.ex:90)
  │       every USER member always receives; an AGENT receives only when @mentioned
  ├─ {:notify, session_events_topic, {:chat_message, …}}   (LV stream, chat.ex:548)
  └─ for each recipient:
       ├─ cross-session (scheme == "session") → re-enter <other>?action=session.send
       └─ otherwise (user|agent)             → dispatch <recipient>?action=<entity>.receive
```

Routing answers **WHO** receives (UNCHANGED). The unified `<entity>.receive` is the **HOW** (split, §3.3). No replacement of the routing layer.

### 3.3 `user.receive` / `agent.receive` — two Behaviors (the entity-communication pattern)

The single `Chat.handle_receive/2` with its internal `case ctx[:kind_module]` (`chat.ex:559-617`) splits into **two first-class Behaviors** (OQ-4), each registered for `:receive` on its own Kind. They are genuinely different (passive inbox vs active live-process delivery) — NOT merged:

```
                       fan-out dispatches <recipient>?action=<entity>.receive
                                      │
        ┌─────────────────────────────┴─────────────────────────────┐
        ▼                                                            ▼
  user.receive  (Behavior.User.Receive, on Entity.User)      agent.receive  (Behavior.Agent.Receive, on Entity.Agent)
   domain.session                                              domain.agent
   • record :last_received + cursor-ring slice                 • build flavor-neutral AgentBridge.Payload
   • SliceChange hook emits the notification                   • AgentBridge.deliver(agent_uri, payload)  ── flavor-blind
   • passive inbox surface                                            │
                                                                      ▼  (transport-neutral)
                                                       ┌──────────────┴───────────────┐
                                                  subprocess-WS mode            in-process-sync mode
                                                  ├─ cc    → EzagentPluginCc.BridgeAdapter
                                                  │           WS push "to_claude" → esr-bridge MCP-subprocess → live claude
                                                  └─ codex → EzagentPluginCodex.BridgeAdapter
                                                              WS push "codex_turn" → codex bridge subprocess
                                                       └─ curl → curl adapter (in-process HTTP LLM call, synchronous)
```

**Transport-neutral `AgentBridge.Adapter` (OQ-5) — widened NOW.** Today's contract (`agent_bridge/adapter.ex`) is WS/Channel-shaped — `socket_path/0`, `channel_topic_prefix/0`, `handle_client_event/3`, `join_info/2` assume a Phoenix-Channel sidecar (research §3.2). The widened contract:

```elixir
defmodule Ezagent.AgentBridge.Adapter do
  @moduledoc "Transport-neutral per-flavor adapter for AgentBridge delivery."

  @type transport_class :: :subprocess_ws | :in_process_sync

  @callback flavor() :: String.t()
  @callback transport_class() :: transport_class()

  # The ONE callback every flavor implements — the transport-neutral delivery seam.
  # For :subprocess_ws the channel_ref is a Channel pid and deliver/2 fires into the WS,
  #   returning :ok — the agent's reply comes back ASYNC through the bridge (→ session.send).
  # For :in_process_sync the channel_ref is nil and deliver/2 performs the HTTP round-trip
  #   in-process, returning {:ok, result} — the result the owning Behavior persists via {:set,…}.
  # (Return type widened to {:ok, term()} for the sync class — see §9 tension 2. Do NOT
  #  narrow back to :ok | {:error}; the curl Behavior depends on the {:ok, result} payload.)
  @callback deliver(Ezagent.AgentBridge.Payload.t(), channel_ref :: pid() | nil) ::
              :ok | {:ok, term()} | {:error, term()}

  # WS-only callbacks — REQUIRED for :subprocess_ws, NOT IMPLEMENTED for :in_process_sync.
  @callback handle_client_event(String.t(), map(), Phoenix.Socket.t()) ::
              {:reply, {:ok | :error, map()}, Phoenix.Socket.t()} | {:noreply, Phoenix.Socket.t()}
  @callback join_info(map(), Phoenix.Socket.t()) :: map()
  @callback socket_path() :: String.t()
  @callback channel_topic_prefix() :: String.t()

  @optional_callbacks handle_client_event: 3, join_info: 2, socket_path: 0, channel_topic_prefix: 0
end
```

**Per-class required-callback contract:**

| Callback | `:subprocess_ws` (cc, codex) | `:in_process_sync` (curl) |
|---|---|---|
| `flavor/0` | required | required |
| `transport_class/0` | required (`:subprocess_ws`) | required (`:in_process_sync`) |
| `deliver/2` | required (channel_ref = Channel pid) | required (channel_ref = `nil`; runs HTTP in-process, returns `:ok \| {:error,_}`) |
| `handle_client_event/3` | **required** | not implemented |
| `join_info/2` | **required** | not implemented |
| `socket_path/0` | **required** | not implemented |
| `channel_topic_prefix/0` | **required** | not implemented |

**The widen reaches every layer that today assumes a socket — not only `deliver/2` (codex MED-2):**

1. **Channel join** (`agent_bridge/channel.ex:51`, `handle_in/3` calls `adapter.handle_client_event/3` unconditionally). PR-0 makes `Channel.join/3` look up the adapter's `transport_class/0` and **REJECT** a join whose flavor is not `:subprocess_ws` (`{:error, %{reason: "transport_class_mismatch"}}`). An `:in_process_sync` flavor must never reach the WS path — there is no socket for it.
2. **`AdapterRegistry.deliver_or_buffer/3`** (`adapter_registry.ex:35`) is guarded `is_pid(channel_pid)` and is the buffering/readiness path. It stays `:subprocess_ws`-only — PR-0 does NOT route `:in_process_sync` through it.
3. **`AgentBridge.deliver_ensuring/3` + `deliver_ensuring_with_flavor/4`** (`agent_bridge.ex:62,86`) — these are what `Chat.Delivery.deliver_agent_receive/2` actually calls (`delivery.ex:269,272`), and they run `Registry.lookup → ensure_ready (heal_fn / LiveJoinRegistry-style await) → deliver`. PR-0 branches them on `transport_class/0`: for `:in_process_sync` they SKIP `Registry.lookup` + `ensure_ready` entirely and call `adapter.deliver(payload, nil)` synchronously (no subprocess to heal, no readiness gate). The low-level `deliver/2` branch alone is insufficient — the readiness gate lives one layer up in `deliver_ensuring*`.
4. **`deliver/2` / `deliver_with_flavor/3`** branch as before: `:subprocess_ws` → `lookup_channel → AdapterRegistry.deliver_or_buffer`; `:in_process_sync` → direct `adapter.deliver(payload, nil)`.

- The WS callbacks become `@optional_callbacks` — cc/codex implement them; curl does not. The contract no longer ASSUMES a socket.
- `AdapterRegistry` learns the transport class per flavor so the channel machinery (`Channel`/`Socket`/`LiveJoinRegistry`-style readiness) is only engaged for `:subprocess_ws` flavors.

### 3.4 The orchestrator-MCP-as-cc-adapter relocation (transport → cc, ops → session)

`agent.receive` is flavor-blind; the orchestrator-MCP surface is a **cc-flavor capability** beneath it, NOT a session-level concern (fixes the §1.6 anomaly). The split is **transport vs operations** (OQ-2):

```
cc plugin (transport)                                   session domain (operations)
─────────────────────                                   ─────────────────────────
McpChannel / McpSocket / McpRegistry  ──┐
orchestrator_bridge.py (2nd subprocess)  │  tools/call   ┌─ Orchestrator.Tools.add_managed_member
CcOrchestratorSeed (--mcp-config seed)   ├─ forward ────▶│  Orchestrator.Tools.define_rule_set_rule
McpServer request plumbing               │  via          │  Orchestrator.Tools.update_template
(tools/list schema, tools/call decode)  ─┘  Invocation   │  Orchestrator.Tools.update_member_template
                                            .dispatch     │  Orchestrator.Tools.remove_member / leave_member
                                            (runtime,     │  Orchestrator.Tools.define_legend / define_prompt_template
                                             not a        └─ (run under the orchestrator's delegated caps)
                                             compile dep)
```

- The cc adapter is the natural owner of the orchestrator MCP server — it ALREADY owns the `--mcp-config` wiring (`cc_agent/spawn.ex:459`; claude merges MCP configs additively). The orchestrator MCP is simply a SECOND MCP server linked into the same `claude` subprocess at launch, symmetric to the cc `reply` (esr-bridge chat) MCP. Both are "things a cc agent can DO."
- `McpServer.handle_tool_call/3` becomes a **forward**: it decodes the `tools/call`, then `Invocation.dispatch`es into the session domain to a **named session action** (`session://…?action=orchestrate.<tool>`, on the session-side `OrchestratorAdmin`/`Orchestrator.Tools` surface) that **reconstructs the orchestrator's 4 delegated caps session-side at the dispatch chokepoint** (O-4), then runs the op. The cc transport carries ONLY the orchestrator's caller URI — it supplies NO ambient authority and the delegated caps never cross the plugin boundary, so there is no cap loss and no plugin-minted authority. This is a **runtime dispatch edge (cc → session)**, NOT a compile dependency — same shape as the `reply` tool dispatching `session.send` (research §3.3). Caps normalize at the chokepoint (Invariant #19); the reconstruction is scope-bounded narrowing only (Invariant #5). No session-mutation logic lands in the plugin (preserves the three-tier rule + Invariant #1).
- The two cc subprocess MCP servers (esr-bridge chat bridge + orchestrator bridge) stay **independent** with independent readiness gates (`LiveJoinRegistry`, separate Channels — `mcp_channel.ex:46-53` rationale is sound and survives the move, research §3.4). They are both cc-flavor MCP capabilities, but NOT one transport.

### 3.5 The curl-as-flavor migration (CurlAgent Kind → Agent + curl adapter)

**Codex HIGH-1 decomposition: curl STATE is a Behavior, curl TRANSPORT is the adapter.** curl today is stateful — it owns a `:curl_agent` slice (provider/api_url/model/system_prompt/max_history/conversation/last_error/last_tokens), an `:api_keys` slice, the PUBLIC `reset_conversation` + `configure` actions (`curl_agent.ex:91`), and mutates durable state via `{:set, :conversation, …}` / `{:set, :last_error, …}` / `{:set, :last_tokens, …}` effects (`curl_agent.ex:196,215`). An adapter whose contract is `deliver/2 :: :ok | {:error}` CANNOT carry that state. So we split:

```
BEFORE                                          AFTER
──────                                          ─────
Entity.CurlAgent (type_name :curl_agent)        Entity.Agent  (one Kind; curl is a FLAVOR via a stored slice field)
  └─ Behavior.CurlAgent registered                ├─ Behavior.CurlAgent (REPARENTED onto Agent; curl flavor only)
     for (CurlAgent, :receive)                     │    • owns :curl_agent slice + :api_keys
       • handle_receive: in-process HTTP           │    • PUBLIC reset_conversation / configure actions
         LLM call (curl_agent.ex:156)              │    • {:set, :conversation/:last_error/:last_tokens} effects
       • reset_conversation / configure            │    • reply: dispatch session.send back (unchanged shape)
       • {:set,…} conversation/tokens/error        │
       • reply: in-handler chat.send               └─ Agent.receive → AgentBridge.deliver
                                                        └─ curl adapter (transport_class :in_process_sync)
                                                            • deliver/2: ONLY the HTTP round-trip
                                                            • returns {:ok, %{content, usage}} | {:error,_}
                                                            • persists NOTHING
```

- **State stays a Behavior on the unified Agent.** `Behavior.CurlAgent` is REPARENTED onto `Entity.Agent` and composed into the per-instance behavior set ONLY for the `curl` flavor (via the P5 per-instance behavior-set mechanism). It keeps the `:curl_agent` slice, the `:api_keys` slice, the public `reset_conversation`/`configure` actions, and ALL `{:set,…}` effects. The reply dispatch (`curl_agent.ex:307`) becomes `session.send` (§3.1.1), unchanged shape.
- **Only the HTTP round-trip becomes the adapter.** `run_completion/6` + `ApiClient` (the in-process HTTP-LLM call) become the curl `AgentBridge.Adapter` (`transport_class :in_process_sync`). The adapter does the HTTP call and RETURNS the result; it does NOT touch state. The curl Behavior receives the result and emits the `{:set, :conversation, …}` / `{:set, :last_tokens, …}` / `{:set, :last_error, …}` effects. **The adapter delivers; the Behavior owns state/effects.** No Channel, no subprocess, no readiness gate (§3.3 — `deliver_ensuring*` skips `ensure_ready` for `:in_process_sync`).
- **Flavor mechanism (O-2):** `curl` is a **stored slice field** on the Agent slice (read at load), NOT a name-segment prefix. This is what makes the snapshot migration a reversible `kind_type` alias rather than a name rewrite (§6.1).
- Result: **ONE `agent.receive`, three transport adapters** (cc / codex / curl), no parallel curl Kind, no parallel curl `:receive`; curl's statefulness preserved as a flavor-scoped Behavior on the unified Agent. The "one Agent.receive, N adapters" claim loses its asterisk (research §3.1).

### 3.6 Session-owned `OrchestratorReadinessPort` (codex HIGH-3)

**The problem.** `apps/ezagent_domain_instance_message/lib/ezagent/entity/session/orchestrator.ex` calls cc-transport modules DIRECTLY: `Ezagent.Orchestrator.McpChannel.lifecycle_topic/0` (`:280`, for the lifecycle PubSub subscribe), `LiveJoinRegistry.joined?/1`, and `Ezagent.Orchestrator.McpRegistry.register/…` (`:767`). OQ-2 moves `McpChannel`/`McpRegistry`/`LiveJoinRegistry` to the cc plugin. If session keeps calling them by module, that creates a **session → cc-plugin compile edge** — a cycle against the target acyclic graph `im → session → agent` (cc is a plugin that already depends on session-domain symbols). Unacceptable.

**The fix — a session-owned neutral port the cc plugin implements.** Define a behaviour in `domain.session`:

```elixir
defmodule Ezagent.Session.OrchestratorReadinessPort do
  @moduledoc """
  Session-owned, transport-neutral port for orchestrator-MCP readiness/context.
  domain.session calls THIS; a transport plugin (cc) registers an implementation
  at boot. Keeps the `im → session → agent` graph acyclic — session never names
  a plugin module.
  """

  @callback lifecycle_topic() :: String.t()
  @callback joined?(orchestrator_uri :: URI.t()) :: boolean()
  @callback register_context(orchestrator_uri :: URI.t(), context :: keyword()) ::
              :ok | {:error, term()}
end
```

- **Registration (declare, don't call — Invariant #8 / plugin contract):** the cc plugin registers its implementing module into a session-owned registry at boot (e.g. `Ezagent.Session.OrchestratorReadinessPort.put_impl(EzagentPluginCc.Orchestrator.ReadinessAdapter)`), the same shape as the existing `AdapterRegistry`/`BehaviorRegistry` "plugins register UP at boot" pattern. Session resolves the impl via the registry indirection and calls the behaviour — it NEVER references a cc module name.
- **The three call sites in `orchestrator.ex` are rewritten to go through the port:** `lifecycle_topic/0` → `port().lifecycle_topic()`; `LiveJoinRegistry.joined?/1` → `port().joined?(uri)`; `McpRegistry.register/…` → `port().register_context(uri, ctx)`. The cc-side adapter forwards to the relocated `McpChannel`/`McpRegistry`/`LiveJoinRegistry`.
- **If no impl is registered** (e.g. cc plugin not loaded), the port returns a neutral "no orchestrator transport" result (`joined?/1 → false`, `register_context/2 → :ok` no-op) — there is simply no MCP transport, which is correct, not an error. (No silent-drop concern: readiness `false` means the gate holds messages per the existing buffer logic.)
- **PR ordering:** PR-8a INTRODUCES the port + rewrites the three `orchestrator.ex` call sites to use it (while the modules still live in session — pure indirection, no behavior change, all scenarios green). PR-8 THEN relocates the transport modules to cc and registers the cc impl. The port exists BEFORE the relocation, so the relocation never introduces the compile edge. The arch-fitness gate (`session has no compile reference to any cc-plugin module`) is asserted after PR-8.

---

## 4. Relationship to the P5 collapse

**The unified Session Kind IS the P5-1 union.** This design SUBSUMES the old P5-A/P5-1/P5-2/P5-3 (the Session-Kind collapse, `docs/superpowers/plans/2026-06-10-socialware-substrate-p5-collapse-one-kind.md`) and ADDS the im/session/agent domain split + transport unification.

- P5 merges `Entity.Session` + `Entity.SocialwareSession` into ONE parameterized Session Kind whose `behaviors/0` is the union; Templates select the per-instance behavior set (safe ONLY because P1's per-instance `instance_set_gate` denial is merged — P5 plan ¶9). **That single Kind is exactly the Kind this design's `session.send` action lives on.** The domain split needs a single Session Kind to be the chokepoint; P5 produces it.
- **Sequencing already done:** P5-0 / P5-0b (and P1–P4 substrate: instance-set enforcement, surface/turn/config, external adapters) are done. P5 itself was held as "do last, may stay deferred" (P5 plan header). This combined effort un-defers P5 BECAUSE the domain split needs the unified Kind — but keeps P5's load-bearing gate (the P1 denial test on the superset Kind) as a hard merge gate.

### 4.1 Proposed ordered sub-PR list (combined effort)

Each PR keeps ALL scenarios green; TEST DB only; subagents touching `apps/**/*.ex` load `ezagent-developer` + `elixir-phoenix-helper`.

**Two tracks, one effort (codex ORDERING + O-3).** The PRs form a **load-bearing TRANSPORT line** and a **parallel P5-COLLAPSE track**. The transport line does NOT hard-depend on the P5 collapse completing; P5 is the cherry, transport is the cake. They ship as one coherent effort (O-3) but a P5 snag must not stall transport. PR-9 (physical domain split) is LAST regardless, gated by acyclic arch-fitness.

- **TRANSPORT line (load-bearing, does NOT wait on P5):** PR-0 → PR-1 → PR-2 → PR-6 → PR-7 → PR-8a → PR-8 → PR-9.
- **P5-COLLAPSE track (parallel, own DEFER valve):** PR-3 → PR-4 → PR-5.
- **Only coupling:** if the P5 collapse lands, PR-1/PR-2/PR-6 register their actions on the UNIFIED Session/Agent Kind; if P5 is deferred (§6.3), they register on the still-separate Kinds (`session.send` on both Session Kinds). Either way the transport line completes. PR-9's physical split can proceed against either the merged or the still-two Session Kinds.

| # | Track | PR | What | Gate |
|---|---|---|---|---|
| **PR-0** | transport | Adapter contract widen (OQ-5, **MED-2**) | Add `transport_class/0` + make WS callbacks `@optional_callbacks`; branch `deliver/2` AND `deliver_ensuring/3` AND `deliver_ensuring_with_flavor/4` on transport class; reject non-`:subprocess_ws` at `Channel.join/3`. cc/codex unchanged (declare `:subprocess_ws`). | cc + codex scenarios green; no curl yet; a non-`:subprocess_ws` join is rejected; the readiness gate is bypassed only on the `:in_process_sync` branch. Pure additive. |
| **PR-1** | transport | `session.send` first-class action + **chat.send sweep (OQ-3, MED-1)** | Add `session.send` action; migrate ALL external `chat.send` callers (§3.1.1 list) to `session.send`; `InboundDispatcher` calls `Session.send/3` (keep `mode`). Demote `chat.send` to internal ONLY after the sweep-complete gate. | Feishu inbound green; `:call` cap-denial still surfaces; **invariant test: no external `chat.send` caller remains**; no symbol-level agent reach from im. |
| **PR-2** | transport | Split `chat.receive` → `user.receive` + `agent.receive` (OQ-4) | Extract the User branch (`chat.ex:561-604`) → `Behavior.User.Receive` (`user.receive`) and the Agent branch (`chat.ex:606-611` → `Delivery.deliver_agent_receive/2`) → `Behavior.Agent.Receive` (`agent.receive`); retire the internal `case kind_module` (`chat.ex:559`). | send/receive/join/leave + cold-restart round-trip green; cc/codex deliver via `agent.receive`. |
| **PR-3** | P5 | P5-1 union Session Kind | Unified Session Kind `behaviors/0` = union; Templates select per-instance behavior set (P1 `BehaviorSet.init_set/2`); `session.send` + `user.receive` ride the unified Kind. | **P1 denial test holds on the superset Kind** (load-bearing); fresh chat + fresh socialware behave as the separate Kinds. |
| **PR-4** | P5 | P5-2 Session snapshot migration | Map existing `Session` + `SocialwareSession` `kind_snapshots` rows → unified Kind via reversible `kind_type` alias with materialized behavior set; cold-restart-safe + reversible. | Cold-restart of a pre-P5 chat AND socialware session each rehydrate byte-identical on the unified Kind. TEST DB. |
| **PR-5** | P5 | P5-3 retire dead Session split | Remove `SocialwareSession`/duplicate Session module(s) — ONLY after PR-4 alias proven reversible. | Arch fitness: no orphaned Kind; duplicate-fn / FF checks pass. |
| **PR-6** | transport | curl-as-flavor: Agent gains curl, STATE-as-Behavior (OQ-1 part 1, **HIGH-1**) | Reparent `Behavior.CurlAgent` (the `:curl_agent` slice + `reset_conversation`/`configure` + `{:set,…}` effects) onto `Entity.Agent`, composed for the curl flavor only; extract ONLY the HTTP round-trip → curl `AgentBridge.Adapter` (`:in_process_sync`); add the stored `curl` flavor slice field. NEW curl agents spawn on the unified Agent Kind. | A fresh curl agent receives via `agent.receive` → curl Behavior → curl adapter (HTTP) → curl Behavior persists conversation via `{:set,…}`; `reset_conversation`/`configure` still work; reply via `session.send`; behavior-identical to old CurlAgent. |
| **PR-7** | transport | curl snapshot migration + retire `Entity.CurlAgent` (OQ-1 part 2, **HIGH-2**) | Add reversible `kind_type: curl_agent → Entity.Agent` alias in `agent_module_resolver.ex` (NOT delete the `:106` map yet); migrate `curl_agent` snapshots (`:curl_agent` + `:api_keys` slices, `:creator_uri` preserved) → unified Agent + `curl` flavor slice; migrate `:curl_agent` cap-axis subjects → `:agent`. Delete `Entity.CurlAgent` + its Behavior registration + Template-as-Kind ONLY after the alias + migration prove reversible. | Cold-restart of a pre-migration curl agent rehydrates on the unified Agent Kind with identical conversation + keys + `:creator_uri`; rollback restores the pre-migration shape. TEST DB. |
| **PR-8a** | transport | **NEW — `OrchestratorReadinessPort` (HIGH-3)** | Define `Ezagent.Session.OrchestratorReadinessPort` in domain.session; rewrite the three `orchestrator.ex` call sites (`:280` `lifecycle_topic`, `joined?`, `:767` `McpRegistry.register`) to go through the port; cc registers a passthrough impl at boot (modules still in session). Pure indirection, no behavior change. | All orchestrator/relay scenarios green; session calls the port, not the cc transport modules directly. |
| **PR-8** | transport | Orchestrator-MCP relocation (OQ-2, **O-4**) | Move `McpChannel`/`McpSocket`/`McpRegistry`/`LiveJoinRegistry`/`CcOrchestratorSeed`/`orchestrator_bridge.py` + `McpServer` request plumbing → cc plugin; cc impl of the port forwards to the relocated modules; `McpServer.handle_tool_call/3` forwards `tools/call` via `Invocation.dispatch` to the named session action that reconstructs the 4 delegated caps session-side (O-4); `Orchestrator.Tools` ops STAY in session. | The 7 orchestrator tools still mutate session state under reconstructed delegated caps; relay/orchestrator E2E green; **arch fitness: session has NO compile reference to any cc-plugin module / MCP / orchestrator-bridge.** |
| **PR-9** | transport | Domain split: physically move modules into im / session / agent apps | Create/realign the domain apps; move modules per §2; enforce `im → session → agent` acyclic deps (mix arch fitness). | Compile graph acyclic; im has no agent symbol; session has no MCP symbol; full umbrella regression + arch fitness + lifecycle invariants. |

Notes on ordering: PR-0..2 are transport/receive refactors safe on TODAY's Kinds; PR-6..7 are the curl Kind migration (state-as-Behavior + reversible-alias migration); **PR-8a introduces the readiness port BEFORE PR-8 relocates the transport** (so the relocation never creates a session→cc edge); PR-9 is the physical domain realignment last (after every module's target is settled). The P5-COLLAPSE track (PR-3..5) runs in parallel with its own DEFER valve (§6.3) and does NOT block the transport line. PR-9 can be split per-domain if blast radius warrants.

---

## 5. Naming decision — DECIDED: `domain.session` (rationale record)

**Domain name for the session substrate: `domain.session`.** (O-1, decided.) Recorded rationale:

- The codebase already has a **socialware substrate** (the P-series: SessionView + registry, Surface/Turn, the socialware Templates) and the P5 plan lives under `socialware-substrate-p5-collapse`. The unified Session Kind is the socialware substrate's one Kind.
- **Decision: name the domain `session` (domain.session), not `socialware`.** Rationale: (a) "session" is the ubiquitous noun across IM/chat/orchestrator/socialware — socialware is ONE Template flavor over the session substrate, not the substrate itself; naming the domain after one flavor inverts the generalization the P5 collapse achieves. (b) The 3-domain mental model "im → session → agent" reads cleanly; "im → socialware → agent" does not. (c) `chat`/`orchestrator`/`advisor`/`page` are all Templates on the same session Kind — `session` is the honest superset name.
- **The existing `socialware` artifacts stay** (substrate docs + the P5 plan path describe one flavor, not the domain). Only the DOMAIN LABEL is `session`. The Kind is one; the name is settled before PR-9 names the app (renames are expensive per the snapshot-key + call-site coupling, cf. `chat.ex:101-110` — hence deciding now, not at PR-9).

---

## 6. Migration safety

**TEST DB ONLY for all migrations.** No destructive migration against any live/dev DB while phx.server uses the affected tables (memory `feedback_destructive_migration_anti_pattern`).

### 6.1 Snapshot / Kind changes

1. **P5 Session collapse (PR-4):** existing `Session` + `SocialwareSession` `kind_snapshots` rows must resolve `kind_type` to the unified Session Kind with the correct materialized behavior set from their persisted `:kind_base` (P1 already persisted the set; cold-load reloads it). **Alias vs rewrite** — must be cold-restart-safe + reversible (P5 plan open decision #3). Gate: the cold-restart respawn round-trip is byte-identical per instance, and the P1 per-instance denial set is preserved.
2. **curl Kind → Agent flavor (PR-7) — reversible `kind_type` alias, NOT a destructive rewrite (codex HIGH-2, O-2):** the cold-load resolver `agent_module_resolver.ex:106` today maps `"curl_agent" -> Entity.CurlAgent`. Deleting `Entity.CurlAgent` before migration breaks every existing `curl_agent` snapshot row. The migration is concretely:
   1. **Add the alias** in `agent_module_resolver.ex`: `kind_module_from_kind_type("curl_agent")` resolves to `Ezagent.Entity.Agent` (the unified Kind). The alias is RETAINED through a rollback window — old rows continue to load.
   2. **Set the flavor slice field** to `"curl"` on the migrated Agent slice (O-2: flavor is a stored slice field, read at load — this is what lets the migration be an alias, not a name rewrite).
   3. **Carry the slices forward unchanged:** the `:curl_agent` slice (provider/api_url/model/system_prompt/max_history/conversation/last_error/last_tokens) + the `:api_keys` slice. `:api_keys` already exists on `Entity.Agent` (no shape change). The reparented `Behavior.CurlAgent` (HIGH-1) owns the `:curl_agent` slice on the unified Kind, so the slice shape is preserved.
   4. **Migrate the cap-axis subjects** `:curl_agent → :agent` (curl's actions were keyed on the `:curl_agent` subject axis; on the unified Kind they key on `:agent`). `reset_conversation` / `configure` cap subjects move with them.
   5. **Preserve `:creator_uri`** data-owner provenance (key-rotation authz depends on it).
   6. **Delete `Entity.CurlAgent`** (and remove the `:curl_agent` resolver branch's old target) ONLY after the alias + migration land and a rollback is proven to restore the pre-migration shape. Until then the alias makes the change reversible.
   Gate: cold-restart of a pre-migration curl agent rehydrates with identical conversation + keys + `:creator_uri` + `curl` flavor on the unified Agent Kind; a rollback within the window restores the old shape.
3. **No back-compat shims** (SPEC v2 §5.11 / memory `feedback_let_it_crash_no_workarounds`): delete the legacy `Entity.CurlAgent` / `Entity.SocialwareSession` paths; don't keep them alongside. DB data is migrated (or wiped+rebuilt) per the migration step, not dual-pathed.

### 6.2 In-flight process drain

- **Agent transport change (PR-0/PR-2/PR-6):** live cc/codex MCP-subprocesses and curl in-process turns in flight during a deploy. The `:subprocess_ws` readiness/buffer machinery (`AdapterRegistry.deliver_or_buffer`, `LiveJoinRegistry`) already buffers until the subprocess re-joins — preserve it. For `:in_process_sync` (curl) there is no subprocess to drain; an in-flight HTTP turn completes or fails-and-retries via `session.send` as today.
- **Orchestrator-MCP relocation (PR-8):** the orchestrator bridge subprocess + its Channel must re-establish after the module move. Keep the independent readiness gate (`LiveJoinRegistry`) so an in-flight `tools/call` buffers/re-issues rather than dropping (Invariant #9 — no silent drop). Verify against a live orchestrator before merge per the E2E bar.

### 6.3 Behavior-preservation + test strategy

- **Behavior-preserving by construction:** PR-1..3 are rename/split/union over UNCHANGED routing + fan-out machinery; the fan-out (Resolver/RuleStore/mentions) is reused wholesale (§3.2). The P1 denial test is the load-bearing gate for the union (§4).
- **Invariant test per architectural goal** (memory `feedback_completion_requires_invariant_test`): a test that FAILS if the domain split is unmet — e.g. an arch-fitness test asserting (a) the im app has NO compile reference to any agent Kind / `agent.receive` symbol, (b) the session app has NO reference to `McpChannel`/`orchestrator_bridge`, (c) the dep graph `im → session → agent` is acyclic. This is the gate, not "tests pass + PRs merged."
- **E2E (every existing scenario green):** chat core (send/receive/join/leave/owner-first-join/cap grants; cold-restart respawn; `{:from}`→orchestrator relay); socialware (SW-DEV/USE/UPD; surface put_version→approve; settlement commit; customer-visibility gating); the cc + codex + curl deliver-and-reply paths; external SPA + Feishu mirror; full umbrella regression + arch fitness + lifecycle invariants.
- **Every distinct E2E bug earns a fast regression test** before landing the fix (memory `feedback_e2e_failure_earns_unit_test`); fix the production flow, not the harness (`feedback_e2e_faces_production`).
- **DEFER criterion inherited from P5:** if PR-3/PR-4 cannot reach all-scenarios-green at acceptable risk on live-shaped data, the Session collapse (PR-3..5) stays deferred and the domain split proceeds against the still-two Session Kinds (with `session.send` registered on both) — the transport unification (PR-0..2, 6..9) does not strictly require the collapse, only a single `session.send` entry. The collapse is the cherry; the transport unification is the cake.

---

## 7. Decided design points (formerly open — now resolved, rev 2)

These were §7 open questions in rev 1. Allen decided them; recorded here as design.

> **O-1 — Domain name = `session` (`domain.session`).** (§5) socialware is ONE Template flavor over the session substrate; the domain is named for the honest superset, not one flavor. The existing `socialware` substrate naming + P5 plan path stay where they are (they describe one flavor); only the DOMAIN label is `session`.

> **O-2 — curl flavor = stored slice field; migration = reversible `kind_type` alias.** (§3.5, §6.1) The `curl` flavor is a stored field on the Agent slice (read at load), NOT a name-segment prefix. The migration adds a reversible `kind_type: curl_agent → Entity.Agent` alias (retained through a rollback window); `Entity.CurlAgent` is deleted only after the alias + migration prove reversible. Concrete 6-step migration in §6.1.

> **O-3 — ONE effort; P5 decoupled at the merge gate.** (§4.1, §6.3) P5 collapse + domain split ship as one coherent effort, but the transport line (PR-0,1,2,6,7,8a,8,9) does NOT hard-depend on the P5 collapse (PR-3,4,5) completing — P5 is a parallel track with a DEFER valve. If P5 risk is high, the domain split proceeds against the still-two Session Kinds with `session.send` registered on both.

> **O-4 — The orchestrator's 4 delegated caps are reconstructed session-side at the dispatch chokepoint.** (§3.4) `McpServer.handle_tool_call/3` forwards `tools/call` to a named session action (`session://…?action=orchestrate.<tool>`) that reassembles the delegated caps session-side (Invariant #19 normalize-at-chokepoint, Invariant #5 narrow-only). The cc transport carries ONLY the orchestrator's caller URI — no ambient plugin authority crosses the boundary, no cap is lost.

---

## 8. Honest risks

- **curl Kind migration (PR-6/7) — high.** A Kind deletion + snapshot migration of live curl-agent conversation + credential state. The `:creator_uri` data-owner provenance MUST survive or key-rotation authz breaks. Mitigated by TEST-DB-only + the reversible `kind_type` alias + the cold-restart byte-identical gate, but it is the riskiest non-P5 piece.
- **curl state/transport split (PR-6, HIGH-1) — medium.** Reparenting `Behavior.CurlAgent` onto `Entity.Agent` while extracting ONLY the HTTP round-trip into the adapter is a non-mechanical split: the boundary between "what the Behavior persists via `{:set,…}`" and "what the adapter returns" must be exact, or curl loses conversation/token state. Mitigated by the behavior-identical gate (fresh curl agent round-trip + `reset_conversation`/`configure` still work). **NEW TENSION:** the curl adapter's `deliver/2` must RETURN the completion result `{:ok, %{content, usage}}` so the Behavior can persist it — but the rev-1 adapter contract typed `deliver/2 :: :ok | {:error}`. The `:in_process_sync` `deliver/2` therefore returns a richer success shape than `:subprocess_ws` (which is fire-into-WS, `:ok`). See §9 note 2 — the contract must allow `{:ok, term()}` for the sync class.
- **Domain-split blast radius (PR-9) — high.** Physically moving ~3 domains' modules touches mix deps, the boot/registration order (plugins register UP at boot), and every cross-module reference. Mitigated by doing it LAST (every target settled) and by the acyclic-dep arch-fitness gate; can be split per-domain if needed.
- **P5 collapse (PR-3/4) — high, inherited.** The superset-Kind safety rests entirely on the P1 per-instance denial gate; the snapshot migration on live-shaped data is the P5 plan's own highest-risk item. DEFER criterion (§6.3) is the escape valve. Now a PARALLEL track (§4.1) so a P5 snag cannot stall the transport line.
- **Orchestrator-MCP relocation (PR-8 + PR-8a) — medium.** Clean tier-wise (transport→cc, ops→session) but invasive; the cc adapter gains a session-facing runtime dispatch edge for `tools/call`. Acceptable (runtime dispatch, not compile dep — same as `reply`), but the readiness-gate independence must survive the move or in-flight `tools/call` drops. The `OrchestratorReadinessPort` (PR-8a) is the new piece that keeps the graph acyclic — its risk is low (pure indirection introduced before the move).
- **Transport-neutral adapter (PR-0) — low.** Purely additive; cc/codex unchanged behind `:subprocess_ws`.

---

## 9. Follow-ups + new tensions surfaced (rev 2)

1. **LOW (codex, note-don't-block) — IM resolves agent mentions directly.** `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/mention_parser.ex:134` resolves `@`-mentions to agent identities IM-side. This is an ingestion-time convenience that technically lets the im domain NAME an agent (a soft violation of goal #1 "no agent symbol in im scope"). It does not dispatch to the agent (routing/mention-gating still happens session-side via `Routing`), so it is not a transport leak — but it should be routed behind a **session query facade** (resolve `@name → member URI` via a session-owned lookup, im passes the raw mention text to `session.send` and session resolves) as a follow-up. Tracked here, NOT a blocker for this effort.

2. **NEW TENSION — adapter `deliver/2` return shape for `:in_process_sync`.** The rev-1 contract typed `deliver/2 :: :ok | {:error, term()}`. But HIGH-1's decomposition requires the curl `:in_process_sync` adapter to RETURN the completion `{:ok, %{content, usage}}` so the curl Behavior can persist it via `{:set,…}`. A fire-into-WS `:subprocess_ws` `deliver/2` legitimately returns bare `:ok` (the reply comes back asynchronously through the bridge, not from `deliver/2`). **Resolution baked into §3.3:** widen the `deliver/2` success type to `:ok | {:ok, term()} | {:error, term()}`, where `:subprocess_ws` returns `:ok` (async reply) and `:in_process_sync` returns `{:ok, result}` (sync reply the Behavior consumes). This is consistent with the per-class contract table — flag it explicitly so the PR-0 implementer does not narrow the type back to `:ok | {:error}`.

3. **NEW TENSION — who invokes the curl adapter, `agent.receive` or the curl Behavior?** HIGH-1 puts state in the Behavior and transport in the adapter, but the adapter is reached via `AgentBridge.deliver` from `agent.receive` (§3.3), which is flavor-blind. For `:subprocess_ws` the reply is async (bridge → `session.send`), so `agent.receive` calling `deliver` and getting `:ok` is the whole story. For curl, the SYNC result must get back to the curl Behavior to be persisted. Two viable shapes: (a) `agent.receive` calls `deliver`, gets `{:ok, result}`, and re-dispatches into the curl Behavior's `handle_completion` action (keeps `agent.receive` flavor-blind but adds a hop); or (b) the curl Behavior IS what `agent.receive` dispatches to for the curl flavor, and it calls `AgentBridge.deliver` itself, persisting the sync return inline (keeps it one hop but makes `agent.receive` flavor-aware for the sync class). **Lean: (a)** — preserves `agent.receive` flavor-blindness (the whole point of OQ-4/OQ-5) at the cost of one extra in-process dispatch; PR-6 must pick one. Flagged for the implementer; not resolved in this design because both honor HIGH-1's state/transport split and the choice is a code-shape call best made against the real `agent.receive` handler.
