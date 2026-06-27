# AutoService flavor-agnostic reframe (research, not impl)

**Question (the lead's framing).** AutoService Tier-1 needs an agent that
(a) holds the `orchestrator` responsibility and (b) can run a TOOL-LOOP to call
`kb_query`. The standing assumption is "this must be a *cc*-orchestrator."
The lead pushes back: `orchestrator` is now a flavor-agnostic ROLE (role-as-data),
and tool-use *should* be flavor-agnostic — any tool-use-capable flavor should be
able to `kb_query`. Is "only cc reaches the tool-loop" a real architectural
limitation, or just that the curl/py flavors haven't implemented a tool-loop?

**Answer in one line.** It is **not** an architectural limitation. The
`orchestrator` role and the `kb_query` *executor* are already flavor-agnostic
shared-domain code (proven by a non-cc test flavor exercising them green); the
only cc-coupled pieces are the **tool-loop runtime + its MCP transport + wire
schemas + persona delivery + the materialization seam** — all of which live in
`apps/ezagent_plugin_cc/`, are addable for another flavor *without touching the
shared layer*, and are "unimplemented for curl/py," not "blocked."

This is a code-cited research note. It changes no code. All citations are
against `origin/main` (worktree base `9428570f`).

---

## 1. The actual tool-loop / `kb_query` path today

There are **three distinct layers**. Conflating them is what produces the false
"must be cc" conclusion.

### Layer A — the *executor* (flavor-agnostic, shared domain)

`kb_query` is an orchestrator tool whose implementation is plain
session-domain code, not cc code:

- `Ezagent.Orchestrator.Tools.kb_query/4`
  (`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex:774-777`)
  delegates to `Ezagent.Orchestrator.Tools.Kb`
  (`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/kb.ex`), which
  `Invocation.dispatch`es `kb.query` to a `kb`×`native` agent in the
  orchestrator's workspace (`tools/kb.ex:941-953`). No flavor anywhere in this
  path.
- The per-orchestrator *executor* is `Ezagent.Session.SessionManager`
  (`apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`) — a
  plain GenServer in the **session domain**. Its moduledoc is explicit: it is an
  "EXECUTION MECHANISM," authenticated by a **bridge token** verified via
  `Ezagent.AgentBridge.TokenStore.verify_token/2` (`session_manager.ex` step 0),
  with the orchestrator's caps reconstructed *session-side*
  (`load_orchestrator_caps/1` = `Ezagent.Identity.list_caps_for/1`).
- `run_tool_op(:kb_query, args, opts)` (`session_manager.ex:474-479`) is
  **structurally identical** to `run_tool_op(:add_managed_member, …)` and every
  other tool: extract JSON args → call `Tools.<tool>(…, opts)`. The caller/cap
  context comes entirely from `opts`; nothing about it is cc-shaped.

The executor is spawned by the **session lifecycle**, not by cc:
`Ezagent.Session.SessionManager.ensure_for_session/1` is called from
`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:760`
on the `session` SpawnRegistry rehydrate route — for *any* session that has an
`orchestrator_uri` in its working copy (a session without one is a no-op
`{:ok, :no_orchestrator}`). The arch-scan comment is blunt: *"cc spawns nothing
itself"* (`apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex:55`).

### Layer B — the *transport* (cc-plugin, but holds zero authority)

The wire plumbing a live `claude` orchestrator reaches the executor through is
cc-plugin code:
`Ezagent.Orchestrator.McpServer`
(`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex`) +
`McpChannel` + `mcp_socket` + `priv/orchestrator_bridge.py`. Its own moduledoc
calls it *"Pure transport, ZERO authority … holds NO capabilities."* It does
exactly three things: serve `tools/list` schemas
(`McpServer.ToolCatalog.tool_schemas/0`,
`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex:8`),
decode a `tools/call` and forward `{:run_tool, tool, arguments, bridge_token}`
to the session-domain `SessionManager` *by URI* (no compile dependency — cc
deps `ezagent_domain_session` only `:test`), and encode the result. The bridge
token it forwards is the orchestrator's *connection credential*, not caps.

### Layer C — the *tool-loop* itself (the flavor runtime)

The agentic loop — "prompt → LLM → decide a tool_call → execute → feed result
back → repeat until a final answer" — is **not ezagent code at all** for cc. It
runs *inside the `claude` CLI subprocess*. ezagent only provides the MCP server
(Layer B) the CLI talks to via `--mcp-config`. cc gets the loop "for free"
because the `claude` binary natively runs an agentic MCP tool-loop.

### Why scenario-13 observed "only cc reaches `run_tool_op(:kb_query)`"

Because cc is the **only flavor whose runtime currently runs a Layer-C loop**
(`docs/e2e/scenario-13-autoservice-end-to-end.md`, the S3 flavor note). The
other shipped flavors don't have a loop:

- **curl / DeepSeek** (scenario-07) is **single-shot HTTP**. Its API client
  `EzagentPluginCurlAgent.ApiClient.chat_completion/1`
  (`apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/api_client.ex:47`)
  posts `%{model, messages, stream: false}` and reads
  `choices[].message.content`. There is **no `tools` field, no `tool_calls`
  handling, no loop** — the "What the function does NOT do" block confirms the
  minimal scope. So curl never reaches `run_tool_op(:kb_query)` — not because it
  *can't*, but because nothing wires a loop.
- **py `*_default`** is an **echo** — no LLM, no tool call.

So the observation is **correct but about Layer C**, and was mis-generalized
into "the tool-loop is a cc capability." It is not. **Layers A and B are
flavor-agnostic; only Layer C is per-flavor-runtime, and only cc has one.**

---

## 2. Is tool-use flavor-agnostic-capable? (and what it would take)

**Yes — the shared contract already supports it; the gap is per-flavor runtime
work, none of it in the shared layer.**

### Evidence that the shared layer is already flavor-agnostic

1. **The role is flavor-agnostic by construction.**
   `Ezagent.Orchestrator.OrchestratorRole`
   (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_role.ex`) is a
   role-as-data recipe (`recipe/0` returns skills + persona + requested_caps,
   *"names no flavor field"*). Its moduledoc states the role *"would compose
   identically against a future `codex` / `curl` flavor (the §6 invariant,
   proven by `Ezagent.Role.ComposeTest`)."* It is registered by name
   ("orchestrator") in `Ezagent.Agent.RoleRegistry` via the `roles/0` plugin
   callback. (Note: it currently lives under `plugin_cc/` and its persona is
   delivered into a `CLAUDE.md` referencing the `esr-orchestrator` MCP server —
   that *delivery* is a cc seam; the recipe *content* is flavor-blind.)

2. **The executor is reachable with no live cc runtime — observed.**
   `apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex`
   mints a bridge token (`TokenStore.mint/1`), `SessionManager.ensure_started`s
   an executor, and drives the full orchestrator tool surface via
   `run_tool(orch, "add_managed_member", …)` → `SessionManager.run_tool` →
   `run_tool_op` — **with no live `claude` process** (the orchestrator is a bare
   `Kind.spawn(Agent, …)`). This proves the token→`SessionManager`→`run_tool_op`
   path needs no cc *runtime*. (The orchestrator URI is still
   `AgentFlavorAttributes.put(…, "cc")`-tagged, but nothing in the executor path
   reads or branches on that tag.)

3. **A non-cc flavor exercises the `kb_query` retrieval green — observed.**
   `apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs` runs the
   Tier-1 seed with `autoservice_flavor: "autosvc-test-…"` — an explicitly
   **non-cc** flavor — and the comment notes *"The generic test flavor IS
   create_agent-supported (unlike live cc)."* It then calls
   `Ezagent.Orchestrator.Tools.kb_query(seed.kb_agent_name, probe, 5, opts)`
   with the orchestrator's **read-back** caps (caps fetched via
   `Identity.list_caps_for`, the same source the live `SessionManager` uses) and
   asserts the corpus-only fact `ZEPHYR-7731` is retrieved + a `granted`
   `kb:query` audit row exists; a no-cap principal is denied.

4. **The seed already abstracts flavor.** `Ezagent.AutoService.Tier1Seed`
   (`scripts/autoservice_tier1_seed.exs`) parameterizes `:autoservice_flavor`
   (default `"cc"`, *"the test passes a generic tool flavor"*) and explicitly
   splits the two "souls": the **RETRIEVAL soul** (the `kb.query` dispatch +
   granted audit row) is labeled *"Flavor-independent"*; only the **ANSWER soul**
   (a chat reply weaving the fact in) *"needs the live cc tool-loop."*

> **Strength of the evidence (state this honestly).** No single test runs a
> non-cc flavor *end-to-end through `SessionManager.run_tool` into `kb_query`
> via an LLM loop*. The end-to-end claim is a **sound composition of three
> partial proofs**: (2) shows token→`SessionManager`→`run_tool_op` works with no
> cc runtime (for the member tools); (3) shows `Tools.kb_query` works under a
> non-cc orchestrator's read-back caps; and `run_tool_op(:kb_query)` is
> *structurally identical* to the member-tool ops already driven in (2). The
> inference is robust because the executor path is uniform across tools — but it
> is a composition, not an observed single test.

### What it would take for a non-cc tool-loop flavor (e.g. curl/DeepSeek with
`tool_calls`, or a py loop)

None of these touch the shared (domain/core) layer; all are cc-*plugin*-located
work to generalize or re-implement:

| Piece | Today | What a non-cc flavor needs |
|---|---|---|
| **The agentic loop (Layer C)** | cc inherits it from the `claude` CLI; curl is single-shot (`api_client.ex:47`) | Implement a loop: present tool schemas, parse `tool_calls`, execute, feed results back, repeat. OpenAI-compatible APIs already support `tool_calls`, so for curl/DeepSeek this is *unimplemented*, not *blocked*. |
| **MCP transport (Layer B)** | `McpServer`/`McpChannel`/`mcp_socket`/`orchestrator_bridge.py`, all in `plugin_cc` | A transport to the executor. Cheapest path: reuse `TokenStore.mint` + call `SessionManager.run_tool(orchestrator_uri, tool, args, token)` directly (exactly what `agent_contract_g4` does) — no MCP server needed if the flavor isn't MCP-native. |
| **Wire tool schemas** | `McpServer.ToolCatalog.tool_schemas/0` (cc-located) | The schemas to present to the LLM. They are not flavor-specific; a non-cc flavor needs them surfaced (lift to a shared catalog, or duplicate). |
| **Persona delivery** | `OrchestratorRole.persona/0` text (flavor-agnostic) written into `CLAUDE.md` referencing `esr-orchestrator` MCP (cc seam) | Deliver the same persona text via the flavor's own system-prompt/config channel. |
| **Materialization seam** | A cc-orchestrator is **not** a `create_agent` role (`{:role_unsupported_for_flavor, "cc"}`); it is materialized only via the session-create orchestrator-template path (`SessionCreator` + `cc_orchestrator_seed.ex` + `orchestrator_bootstrap.ex`) | A way to materialize the role on the chosen flavor (either make the flavor `create_agent`-supported for `orchestrator`, or add a flavor variant of the orchestrator-template path). |

**The honest one-liner:** *role and executor are already flavor-agnostic and
proven so; the loop + transport + schema-presentation + persona-delivery +
materialization are cc-plugin code, addable for another flavor without touching
the shared layer.* That is the precise answer to "real limitation or
unimplemented?" — **unimplemented.**

---

## 3. The reframe — assumptions to change

The cc-locked AutoService flow rests on assumptions that the code does **not**
require:

| Current assumption | Reality | Reframe |
|---|---|---|
| "The AutoService agent must be a *cc*-orchestrator." | `orchestrator` is a role-as-data recipe naming no flavor; the role composes against any flavor (`OrchestratorRole` moduledoc + `Role.ComposeTest`). | Use the `orchestrator` ROLE on **any tool-loop-capable flavor**. |
| "Only cc can call `kb_query` because only cc reaches the tool-loop." | The *executor* (`Tools.kb_query` / `run_tool_op` / `SessionManager`) is shared-domain, bridge-token-authed, proven green under a non-cc flavor. Only the *loop runtime* (Layer C) is cc-only. | Any flavor that runs a loop + can reach `SessionManager.run_tool` (or the MCP bridge) calls `kb_query`. |
| "The orchestrator tools are cc MCP tools." | They are *exposed over MCP by cc* for transport convenience; the tools themselves are domain code with a second non-LLM front door (the world Console; see the agent-console handoff `docs/superpowers/handoffs/2026-06-22-agent-console-in-world-handoff.md` — "two front doors: the cc bridge and the world Console"). | Tools are flavor-agnostic; MCP is one transport, not the contract. |
| "`#505` (cc-PTY) blocks Tier-1." | `#505` is a **cc-flavor-specific** answer-soul blocker (PTY/startup/OAuth). | It matters **only if cc is the chosen tool-loop flavor**. Pick another loop-capable flavor and `#505` drops out entirely (see §4). |

**What in the current autoservice flow/seed hard-codes cc:**

- `Tier1Seed` *defaults* `autoservice_flavor` to `"cc"` — but already accepts an
  override (the test passes a non-cc flavor). The default is a convenience, not
  a constraint.
- The orchestrator persona is delivered via `CLAUDE.md` + the `esr-orchestrator`
  MCP server name (cc seam) — the persona *content* is flavor-blind.
- The orchestrator MCP transport (`McpServer` & friends) is physically in
  `plugin_cc`.
- Materialization of an orchestrator-with-tool-loop currently only exists on the
  cc session-create template path.

**What is genuinely needed vs. just-cc-coupling:** genuinely needed = *some*
flavor runtime that runs a tool-loop and can reach the executor. Everything else
is current cc-coupling, not an architectural requirement.

---

## 4. Existing-mechanism completion — the minimal real gap

With the pieces that **already exist** — the `orchestrator` ROLE (role-as-data,
RoleRegistry) + the KB engine (#1036: `Ezagent.Behavior.Kb`, `kb`×`native`, FTS5,
cap-isolated) + routing (the `always→agent` session-scoped rule seeded in
Tier1Seed) + the bridge-token executor (`SessionManager` + `Tools`) — the flow
is **complete except for one thing: a flavor runtime that runs the tool-loop and
weaves the retrieved fact into a chat reply.**

Tier-1's two "souls" cleave exactly here (per the seed + scenario-13 实测 table):

- **RETRIEVAL soul — DONE and flavor-independent.** `kb.query` retrieves the
  corpus-only fact; a `granted` `kb:query` audit row is written; no-cap is
  denied. Proven deterministically *and* live (the seed test, 20/20 green).
- **ANSWER soul — the remaining gap.** An LLM tool-loop must (a) decide to call
  `kb_query`, (b) get the hit, (c) write a chat reply that quotes the fact.
  Today only cc has a loop, and cc's answer path rides its own PTY/startup
  blockers.

So the **minimal real gap is "a tool-loop on the AutoService agent's flavor,"**
and there are two ways to close it, both using existing mechanisms:

1. **Stay on cc** → the remaining work is the deferred **#505 cc-PTY** answer
   path (and valid `claude` OAuth). This is the *only* reason #505 is on the
   critical path.
2. **Choose another tool-loop-capable flavor** → #505 becomes irrelevant. The
   work is instead: implement an agentic loop on that flavor (for an
   OpenAI-compatible curl/DeepSeek flavor, add `tools` + `tool_calls` handling to
   the single-shot `api_client.ex` and a loop around it), point it at the
   executor (reuse `TokenStore` + `SessionManager.run_tool`, the
   `agent_contract_g4` shape — no new MCP server required), surface the tool
   schemas, deliver the persona, and materialize the orchestrator role on that
   flavor.

**#505 is therefore a flavor *choice* consequence, not an architecture
constraint.** It only matters on path (1).

---

## Summary for the lead

- **Tool-loop path is shared, not cc-specific, except the loop runtime itself.**
  Executor = `SessionManager` + `Tools.kb_query` (session domain,
  `session_manager.ex:474`, `tools/kb.ex`); transport = cc `McpServer`
  (zero-authority plumbing); loop = the `claude` CLI (Layer C, the only
  cc-exclusive part).
- **Tool-use is flavor-agnostic-capable** — the role names no flavor, the
  executor is bridge-token-authed shared code, and a non-cc test flavor drives
  `kb_query` green. What it'd take for another flavor: a tool-loop + a transport
  to the executor + schema/persona delivery + a materialization path — all
  cc-plugin-located, none in the shared layer; "unimplemented," not "blocked."
- **The reframe holds:** drop "must be cc-orchestrator"; use the `orchestrator`
  ROLE on any tool-loop-capable flavor.
- **Minimal real gap:** one tool-loop that weaves the KB hit into a chat reply.
  Retrieval/role/routing/executor already exist. **#505 (cc-PTY) is on the
  critical path *only if cc is the chosen flavor*** — pick another loop-capable
  flavor and it drops out.
</content>
</invoke>
