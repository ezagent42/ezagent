# SPEC — Recipe-driven agentic tool-loop (lift the loop out of the cc flavor)

> **Type:** design SPEC (NOT implementation). **Base:** `origin/main` @ `9428570f`.
> All code citations are against `origin/main`. **Status:** draft for lead +
> codex adversarial review.
>
> **Companion read:** `docs/together/2026-06-26/notes/autoservice-flavor-agnostic-reframe.md`
> (the three-layer A/B/C map this SPEC builds on). **Skills:** `ezagent-developer`,
> `ezagent-socialware`.

## 0. The principle (the lead's decision, restated as the design axiom)

The agentic tool-loop — **LLM decides a `tool_call` → execute the tool → feed
the result back → LLM continues → final reply** — is a **role/recipe concern
(what the agent DOES)**, not a flavor concern. **A flavor is only "how to
start / execute / load the recipe"** — the completion backend.

Today this is violated for exactly one layer: cc hides the *whole loop* inside
the `claude` CLI subprocess (Layer C, reframe note §1). curl is single-shot (no
loop), py is echo. So the loop is currently flavor-coupled. This SPEC makes the
loop a **shared, recipe-driven capability** for completion-only flavors, while
**not destroying claude's native loop** for cc.

The design axiom that makes this defensible (the load-bearing invariant):

> **The tool-set and the executor are shared and recipe-declared; only the LOOP
> RUNTIME is per-flavor. Native-loop flavors (cc) and shared-loop flavors (curl)
> surface the IDENTICAL recipe-declared tool-set through the IDENTICAL executor
> (`SessionManager` / `Tools`) — only who turns the crank differs.**

Everything below is in service of that one invariant.

---

## 1. Current-state map (cited)

There are **three layers**; conflating them produces the false "must be cc"
conclusion (reframe note §1). This SPEC touches Layer C only.

### Layer A — the executor (flavor-agnostic, shared domain) — KEEP AS-IS

- `Ezagent.Orchestrator.Tools.kb_query/4`
  (`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex`) →
  `Ezagent.Orchestrator.Tools.Kb.dispatch_kb/4`
  (`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/kb.ex:40`)
  `Invocation.dispatch`es `kb.query` to a `kb`×`native` agent carrying only
  `caller`/`caps`/`workspace_uri`. No flavor in this path.
- The executor process is `Ezagent.Session.SessionManager`
  (`apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`) — a
  plain GenServer in the **session domain**, bridge-token-authed
  (`TokenStore.verify_token/2`, step 0), caps reconstructed session-side
  (`load_orchestrator_caps/1` = `Identity.list_caps_for/1`).
  `run_tool/4` (`:259`) → `run_tool_op/3` (`:389`–`:487`): each tool is
  `extract JSON args → Tools.<tool>(…, opts)`; `run_tool_op(:kb_query, …)`
  (`:475`) is **structurally identical** to every member tool — the caller/cap
  context is entirely in `opts`, nothing is cc-shaped.

### Layer B — the transport (cc-plugin, ZERO authority) — RE-POINT (not move)

- `Ezagent.Orchestrator.McpServer`
  (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex`) +
  `McpChannel` + `mcp_socket` + `priv/orchestrator_bridge.py`: "Pure transport,
  ZERO authority." It serves `tools/list` schemas
  (`McpServer.ToolCatalog.tool_schemas/0`,
  `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex:8`),
  decodes a `tools/call` and forwards `{:run_tool, tool, args, bridge_token}`
  to `SessionManager` by URI, encodes the result.
- **The 12-tool wire catalog (`ToolCatalog.tool_schemas/0`) is cc-located but
  flavor-blind content.** This SPEC re-points it at a shared catalog so cc and
  the shared loop read the same source (§5.4). The MCP transport itself stays
  in cc — it is the cc-native delivery of the tool-set into the subprocess.

### Layer C — the loop runtime (the ONLY cc-coupled piece) — THE LIFT

The agentic loop runs **inside the `claude` CLI subprocess** for cc, not in
ezagent. ezagent only provides the MCP server (Layer B) the CLI talks to. The
loop is reached through the **bridge** seam:

`agent.receive` (`apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex`)
→ `Ezagent.Behavior.Agent.Delivery.deliver_agent_receive/2` →
`Ezagent.AgentBridge.deliver/2` → the per-flavor **adapter**
(`Ezagent.AgentBridge.Adapter`,
`apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/adapter.ex`).

Two transport classes exist today:

| flavor | adapter | `transport_class` | loop? | tools? |
|---|---|---|---|---|
| cc (interactive) | `EzagentPluginCc.BridgeAdapter` | `:subprocess_ws` | **native** (in CLI subprocess) | yes, via MCP→SessionManager |
| codex | `EzagentPluginCodex.BridgeAdapter` | `:subprocess_ws` | **native** (in codex subprocess) | yes |
| cc-headless (`claude -p`) | `EzagentPluginCc.CcHeadlessBridgeAdapter` | `:in_process_sync` | **native** (claude SDK runs its own loop per call) | yes (claude SDK MCP) |
| curl / DeepSeek | `EzagentPluginCurlAgent.BridgeAdapter` | `:in_process_sync` | **none** (single-shot) | **no** |
| py `*_default` | — | `:in_process_sync` | none (echo) | no |

The `:in_process_sync` path (`receive.ex` `handle_receive/2`): the adapter
returns `{:sync, flavor, result}` SYNCHRONOUSLY; `agent.receive` re-dispatches it
to the flavor's `:sync_result` action which persists conversation + replies via
`session.send`. curl's `deliver/2`
(`apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/bridge_adapter.ex`)
does ONE `ApiClient.chat_completion/1`
(`apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/api_client.ex:47`)
posting `%{model, messages, stream: false}` — **no `tools` field, no
`tool_calls` parsing, no loop**.

### The decisive observation — loop-locality ⟂ transport-class

`transport_class` (`:subprocess_ws` vs `:in_process_sync`) is **sync-vs-async
DELIVERY**, and it is **orthogonal to whether a native loop runs**:

- **cc-headless** is `:in_process_sync` **AND native-loop** — `deliver/2` calls
  `SdkSidecar.query/3` once, but the claude SDK runs a full agentic loop +
  native tool-use *inside* that one call
  (`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/cc_headless_bridge_adapter.ex`).
- **curl** is `:in_process_sync` **AND no-loop**.

So "does this flavor run its own loop?" is **not** encoded anywhere today. The
loop is implicit. The lift makes it **explicit** as a new flavor axis
(`loop_locality`, §4) — *without* overloading `transport_class`.

### The recipe today — `Ezagent.Role` (`apps/ezagent_core/lib/ezagent/role.ex`)

The Role recipe ("the CONTENTS of the sandbox are the ROLE; HOW the sandbox is
loaded is the FLAVOR" — Allen) carries:
`name, passive, skills, plugins, prompt, script, behaviors, requested_caps,
session_template`. `Role.new/1` **rejects any flavor field**
(`@flavor_fields [:flavor, :kind, :bridge_adapter, :template_class]`).
`Ezagent.Orchestrator.OrchestratorRole.recipe/0`
(`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_role.ex:751`)
is registered by name in `RoleRegistry` and is flavor-blind.

**The recipe does NOT declare tools or loop-policy today.** Tools live only in
the cc wire catalog (Layer B). This is the gap: the recipe says *what skills /
persona* the agent has, but the *tool-set the agentic loop may call* is
implicit and cc-located. §5 closes it.

---

## 2. The shared loop — design

### 2.1 What it is

A **recipe-driven agentic loop** that lives in the **session domain** and drives
completion-only flavors:

```
loop(messages, recipe.tools, loop_policy):
  for step in 1..loop_policy.max_steps:
    case flavor.get_completion(messages, recipe.tools, flavor_config):
      {:final, %{content, usage}}      -> return {:final, content, usage}
      {:tool_calls, calls, %{usage}}   ->
        results = for c <- calls: execute_tool(c)        # shared executor
        messages = messages ++ tool_call_msgs(calls) ++ tool_result_msgs(results)
        continue
      {:error, reason}                 -> return {:error, reason}
  return {:error, :max_steps_exceeded}   # loop_policy.on_overflow
```

The loop **orchestrates**; the flavor only **returns a completion** (§3). Any
flavor whose backend returns `tool_calls` (OpenAI-compatible / DeepSeek / a
tool-use curl) drives the same recipe-defined loop.

### 2.2 Where it lives — `Ezagent.Session.CompletionLoop` (session domain)

Placement is constrained by the three-tier acyclic gate. The loop must reach
**three** things: the flavor's completion primitive (in `agent_bridge`), the
tool executor (`SessionManager` / `Tools`, in `domain_session`), and the reply
(`session.send`, in `domain_session`). Dependency directions on `origin/main`
(verified from `mix.exs`):

- `ezagent_domain_agent_bridge` → depends only on `core` (a near-leaf).
- `ezagent_domain_session` → depends on `agent_bridge` **and** `agent` **and**
  owns `SessionManager` + `Tools` + can dispatch `session.send`.

Therefore the runner lives in **`ezagent_domain_session`** (e.g.
`Ezagent.Session.CompletionLoop`). Putting it in `agent_bridge` would force a
forbidden **bridge → session** compile edge (the executor + `session.send` are
session-domain). The completion-primitive *contract* (the new callback) is
declared in `agent_bridge` on the `Adapter` behaviour (down-dep, allowed); the
flavor adapters implement it in their plugins.

> **Invariant to honor (ezagent-developer #1 / acyclic gate):** the runner
> dispatches through `Ezagent.Invocation.dispatch/1` (for `session.send`) and
> calls `SessionManager.run_tool/4` directly (same domain). No `PubSub`
> between Kinds. Run `mix ezagent.check_invariants` + the acyclic gate as the
> placement proof, not type-check.

### 2.3 Async delivery (mirror `:subprocess_ws`), not inline-blocking

A multi-step loop = several LLM calls + tool executions; running it inline in
the Agent GenServer dispatch (the way `:in_process_sync` runs one HTTP call,
see `receive.ex` "KNOWN LIMITATION") would block the Kind for the whole loop.

So the shared loop **delivers asynchronously, like `:subprocess_ws`**:
`agent.receive` spawns the runner (a supervised transient process), returns
`{:ok, %{}, []}` immediately, and the runner dispatches the final reply back
through `session.send` when the loop terminates — exactly the cc/codex async
shape. This reuses the existing async reply path and keeps the Agent Kind
responsive.

### 2.4 Conversation persistence + concurrency (stated, not silent)

- **Intermediate `tool_call` / `tool_result` messages are EPHEMERAL runner
  scratch** — held in the runner's memory for the loop's duration only. They are
  *not* persisted. Only **the user turn + the final assistant answer** persist
  to the flavor's conversation slice (the same `:sync_result`-style append curl
  uses today). This keeps the durable model identical to a single-shot exchange
  and pre-empts "where does the tool-call transcript live?" (answer: nowhere
  durable; it is reconstructed per turn).
- **The `:sync_result` ordering limitation is INHERITED, not fixed here.** The
  final-answer persist is still a separate dispatch (`receive.ex` documents the
  single-slice-commit blocker). Async delivery does not dodge it: two concurrent
  turns to the same agent can still build on a stale conversation snapshot. This
  SPEC **declares the fix out of scope** and points at the existing remedy —
  option 1 in `receive.ex`'s moduledoc (flavor-selected `:receive` behavior
  bound on the flavor's own slice), tracked as a follow-up. The shared loop adds
  no *new* ordering hazard beyond the documented curl one. (Open question OQ-4.)

### 2.5 Tool execution from the loop — the authority path (cited)

For an **orchestrator** agentic agent (the AutoService case), each `tool_call`
maps to:

```
SessionManager.run_tool(orchestrator_uri, name, arguments, bridge_token)
```

— the `agent_contract_g4` shape
(`apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex`):
mint/hold the orchestrator's bridge token (`TokenStore.mint/1`) and call by
URI. SessionManager step 0 verifies the token, step 2 reconstructs the
orchestrator's caps, step 3 dispatches with CapBAC gating **unchanged**. The
orchestrator must HOLD the `kb.query` cap (flavor-blind, fail-closed) — exactly
as the non-cc test flavor does in
`apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs`.

**This reuses the SAME executor door cc uses** (the reframe note's prescription:
"reuse `TokenStore.mint` + call `SessionManager.run_tool` directly — no MCP
server needed if the flavor isn't MCP-native"). We do **not** add a second
authority entry to the executor (OQ-1). The tool-name → executor binding is
declared in the shared catalog (§5.4), so non-orchestrator tools can be added
later without changing the loop.

---

## 3. The flavor completion-primitive contract

A new callback on `Ezagent.AgentBridge.Adapter` (declared in `agent_bridge`,
implemented in the flavor plugin). It is the generalization of curl's
single-shot `ApiClient.chat_completion/1` to (a) accept `tools` and (b) return
either a final answer or tool-calls:

```elixir
@type completion_request :: %{
        messages: [message()],          # system + history + user + scratch turns
        tools: [tool_schema()],         # the recipe-declared tool-set (JSON schema)
        config: map()                   # flavor config: model, api_url, params...
      }

@type completion_result ::
        {:final, %{content: String.t(), usage: map()}}
      | {:tool_calls, [%{id: String.t(), name: String.t(), arguments: map()}],
         %{usage: map()}}
      | {:error, term()}

@callback get_completion(completion_request()) :: completion_result()
```

Properties (mirroring curl's existing stateless adapter):

- **STATELESS.** The adapter reads the agent's persisted config slice from the
  **snapshot store** (deadlock-safe, like curl's `snapshot_slice/2`), assembles
  the HTTP request, parses the OpenAI-shaped response (`choices[].message`:
  `content` → `:final`; `tool_calls` → `:tool_calls`). It performs NO durable
  writes and runs NO loop — the shared runner owns both.
- **Tool-set is INPUT, not flavor-owned.** `tools` is passed in by the runner
  (sourced from the recipe, §5). The flavor never decides which tools exist; it
  only renders them into its wire format and reports the model's tool-call
  decisions back.
- **Only for `loop_locality: :shared` flavors.** Native-loop flavors (cc /
  codex / cc-headless) do NOT implement `get_completion` — they keep their
  `deliver/2` (subprocess WS, or SDK sidecar). The callback is an
  `@optional_callback`, required only for `:shared` flavors (the same per-class
  contract pattern the Adapter behaviour already uses for the WS-only callbacks).

### Responsibility split (recipe owns the loop-policy + tools; flavor owns execution)

| Concern | Owner | Where |
|---|---|---|
| Which tools exist + their schemas | **Recipe** (`tools`) | `%Role{}` → shared catalog (§5) |
| Loop bounds (max_steps, on_error, parallel) | **Recipe** (`loop_policy`) | `%Role{}` (§5) |
| The loop itself (decide→exec→feed-back) | **Shared runner** | `Ezagent.Session.CompletionLoop` |
| Tool execution + CapBAC | **Shared executor** | `SessionManager` / `Tools` |
| One completion (messages,tools → result) | **Flavor** | `get_completion/1` |
| Conversation persist + reply | **Flavor STATE behavior** | `:sync_result` (existing) |
| WHO turns the crank (native vs shared) | **Flavor** (`loop_locality`) | adapter / flavor registry (§4) |

---

## 4. `loop_locality` — the new flavor axis (NOT a recipe field, NOT transport_class)

A flavor declares **where its loop runs**, as a first-class axis separate from
`transport_class`:

```elixir
@type loop_locality :: :native | :shared
@callback loop_locality() :: loop_locality()   # on Ezagent.AgentBridge.Adapter
```

- `:native` — the flavor runs its OWN agentic loop (cc/codex subprocess; cc-
  headless SDK). The runner is NOT engaged. Recipe tools are surfaced via the
  flavor's native channel (cc: MCP `tools/list`, §5.4).
- `:shared` — the flavor returns single completions via `get_completion/1`; the
  shared `CompletionLoop` (§2) drives. (curl-with-tools / OpenAI-compat / a
  DeepSeek tool-use flavor.)

Default = `:native` for existing flavors (no behavior change). This axis is
**flavor-declared**, so it stays OUT of `%Role{}` — `Role.new/1`'s
`@flavor_fields` guard would (correctly) reject a `loop_locality` key in a
recipe (it is a flavor concern, not "what the agent does"). The recipe declares
tools + loop *bounds*; the flavor declares loop *locality*. This is the precise
line that keeps the recipe flavor-agnostic.

### The unifying invariant (§0 made concrete)

```
                 recipe.tools  (single source, shared catalog §5.4)
                   /                         \
   loop_locality :native              loop_locality :shared
   (cc)  MCP tools/list  ──┐          get_completion(tools) ──┐
                           │                                   │
                  same executor:  SessionManager.run_tool / Tools  (Layer A)
                           │                                   │
                  same CapBAC: orchestrator caps reconstructed session-side
```

Native and shared paths surface the **identical** recipe tool-set through the
**identical** executor; only the loop runtime differs. An invariant test should
assert: *the tool-set cc serves over MCP equals the tool-set the shared loop
passes to `get_completion`, for the same recipe* (§7).

---

## 5. Recipe extension (`%Ezagent.Role{}` + `Role.new/1`)

Add two **flavor-agnostic** fields:

```elixir
defstruct [...existing...,
  tools: [],            # [tool_ref :: String.t()] — names resolved in the shared catalog
  loop_policy: nil      # %{max_steps, on_tool_error, parallel_tool_calls?, on_overflow} | nil
]
```

- `tools` — a list of tool-set **refs** (e.g. `["kb_query"]`, or the full
  orchestrator set). Each ref resolves through the **shared tool catalog** (§5.4)
  to `{schema, executor_binding}`. Validated at the `Role.new/1` boundary
  (list-of-strings, like `skills`). NOT a flavor field.
- `loop_policy` — loop BOUNDS only: `max_steps` (int), `on_tool_error`
  (`:surface | :abort`), `parallel_tool_calls?` (bool), `on_overflow`
  (`:final_best_effort | :error`). All flavor-agnostic (they describe the
  agent's behavior, expressible against any loop runtime; a native cc loop maps
  `max_steps` to the CLI's max-turns). `nil` ⇒ engine defaults.

`OrchestratorRole.recipe/0` gains `tools: ToolCatalog tool names`,
`loop_policy: %{max_steps: 8, ...}` — so the orchestrator role declares its
tool-loop as data, and ANY loop_locality renders the same set.

### 5.4 Shared tool catalog (lift Layer B's catalog out of cc)

Today `Ezagent.Orchestrator.McpServer.ToolCatalog.tool_schemas/0` (cc-located,
12 tools) is the only place tool schemas live. Introduce a **shared catalog** in
the session domain (e.g. `Ezagent.Orchestrator.ToolCatalog`) that owns
`{name → schema, executor_binding}` where `executor_binding` is, for every
orchestrator tool, "dispatch via `SessionManager.run_tool/4`." Then:

- cc's `McpServer.ToolCatalog.tool_schemas/0` is **re-pointed** to read the
  shared catalog filtered by the recipe's `tools` (no behavior change — same
  schemas, now sourced from the shared module).
- the shared `CompletionLoop` reads the SAME catalog, filtered by the SAME
  recipe `tools`, to build `get_completion`'s `tools` arg and to map a
  returned `tool_call.name` → executor.

This is the structural change that makes the §4 invariant *true by
construction*: one catalog, two renderers (MCP vs OpenAI-tools), one executor.

---

## 6. The cc reconciliation — recommendation: **(b) pragmatic split**

### The honest weighing

**Option (a): migrate cc onto the shared loop** (cc becomes completion-only,
`loop_locality: :shared`, implements `get_completion`). cc would call `claude`
per-completion and let ezagent drive the loop.

- ✗ **Loses claude's native agentic loop** — its single biggest quality asset:
  native MCP tool-use, context/compaction management, sub-agents, interleaved
  thinking, the CLI/SDK's tuned multi-turn behavior. Reducing `claude` to
  `get_completion(messages, tools)` discards exactly what the `claude` binary
  is *built to be*.
- ✗ Re-implements (worse) what the subprocess already does well; slower
  (per-step process/SDK ceremony); higher blast radius.
- ✗ Buys little: the executor + tool-set are **already** shareable without it
  (Layers A/B + the recipe). The reframe note's own thesis is "only Layer C is
  per-flavor" — forcing Layer C uniform across cc and curl is the over-reach.

**Option (b): shared loop is for completion-only flavors; cc keeps its native
loop as a sanctioned special-case.** `loop_locality: :native` for cc / codex /
cc-headless; `:shared` for curl-with-tools / OpenAI-compat / DeepSeek.

- ✓ Preserves claude's native tool-use quality.
- ✓ cc-headless **proves** the orthogonality is real and clean: a flavor can be
  sync-delivered (`:in_process_sync`) yet run a native loop — so no cc variant
  ever needs the shared loop.
- ✓ The uniformity we actually want — same recipe tool-set, same executor, same
  CapBAC — is achieved at Layers A/B + recipe (§4 invariant), NOT at the loop
  runtime.
- ✓ cc's only change is additive: its `ToolCatalog` reads the shared catalog +
  recipe tool-set (§5.4). No loop migration, no risk to the answer quality.

### Recommendation

**Adopt (b).** cc (interactive + headless) and codex stay `loop_locality:
:native`. The shared `CompletionLoop` serves `:shared` flavors only. The recipe
is the single source of the tool-set for both; the §4 invariant binds them. Do
**not** force cc to lose its native tool-use loop. This is the pragmatic,
production-preserving split, and it is what the reframe note's three-layer model
already implies.

---

## 7. Migration path (phased — this is a deep refactor)

**Phase 0 — this SPEC** (design + lead/codex sign-off).

**Phase 1 — MINIMAL FIRST PR (the proof): a non-cc flavor runs the shared loop
+ `kb_query`, recipe-driven.** Deliberately vertical and narrow:
1. Add `get_completion/1` + `loop_locality/0` to `Ezagent.AgentBridge.Adapter`
   (optional callbacks; default `:native`).
2. Add `tools` + `loop_policy` to `%Role{}` + `Role.new/1` validation.
3. Lift **only `kb_query`'s** schema into a minimal shared catalog entry with
   its `SessionManager.run_tool` binding (defer the full 12-tool lift to
   Phase 3).
4. Implement `Ezagent.Session.CompletionLoop` (the §2 loop, async delivery, max
   2–3 steps) in the session domain.
5. Implement a **tool-use DeepSeek/curl flavor adapter** (`loop_locality:
   :shared`) implementing `get_completion/1`: add `tools` + `tool_calls` to the
   single-shot `ApiClient` and parse them (the reframe note's "unimplemented,
   not blocked" gap). Recipe: `tools: ["kb_query"]`, `loop_policy: %{max_steps: 3}`.
6. Wire it as the AutoService orchestrator flavor; mint its bridge token; drive
   the loop → `SessionManager.run_tool(…, "kb_query", …)` → weave the hit →
   `session.send`.

**Phase-1 completion gate (the invariant test):** the AutoService Tier-1
**ANSWER soul** — which `autoservice_tier1_seed_test.exs` + the reframe note
(§4) call "the remaining gap, needs the live cc tool-loop" — goes **green on the
non-cc shared-loop flavor**: the agent decides `kb_query`, gets `ZEPHYR-7731`,
and quotes it in a chat reply, with a `granted` `kb:query` audit row, capless
denied. Plus a focused unit test: *the shared loop executes a recipe-declared
tool and feeds the result back into the next completion* (this is the
architectural-goal test — it fails if the loop is not recipe-driven). This
closes the exact "minimal real gap" the reframe note identified, on a non-cc
flavor, with `#505` (cc-PTY) dropped out entirely.

**Phase 2 — generalize the catalog + recipe.** Lift the full 12-tool catalog to
the shared module; re-point cc's `McpServer.ToolCatalog` at it (no behavior
change for cc); add `tools`/`loop_policy` to `OrchestratorRole.recipe/0`; add
the §7 cross-renderer invariant test (cc-MCP tool-set == shared-loop tool-set
for the same recipe).

**Phase 3 — harden + broaden.** Decide curl single-shot's fate (degenerate
0-tool shared loop vs keep `:in_process_sync` with opt-in upgrade); address the
`:sync_result` ordering limitation (option 1: flavor-selected `:receive`) if
concurrent-turn correctness is required; add `codex remote` / other tool-use
backends as `:shared` candidates.

cc is **never migrated**. Its only touch is Phase 2's catalog re-point.

---

## 8. Open questions for the lead

- **OQ-1 (executor authority).** The shared loop mints/holds the orchestrator's
  bridge token and calls `SessionManager.run_tool` (the `agent_contract_g4`
  shape). Acceptable to reuse the bridge-token ceremony in-node, or should
  SessionManager grow a trusted in-node entry? **Recommend reuse** — don't add a
  second authority door to the executor (one gate, audited, CapBAC unchanged).
- **OQ-2 (loop_locality home).** Declare `loop_locality` on the `Adapter`
  behaviour (alongside `transport_class`), or on the `AgentFlavorRegistry`? The
  handoff note flags `AgentFlavorRegistry` semantics as discuss-first. Recommend
  the Adapter (it co-locates with `transport_class` + `get_completion`).
- **OQ-3 (tool-set scope per recipe).** Should `tools` be a free list of
  individual tool refs, or named tool-SETS (e.g. `"orchestrator"`,
  `"kb"`)? Sets are more ergonomic + version-stable; refs are more granular.
  Recommend named sets resolving to ref lists in the shared catalog.
- **OQ-4 (concurrency).** Is inheriting the `:sync_result` ordering limitation
  acceptable for the agentic loop (Phase 1–2), with the flavor-selected
  `:receive` fix deferred to Phase 3? (Production single-user turns are
  naturally serialized; the window is concurrent senders to one agent.)
- **OQ-5 (loop_policy bounds on native).** `max_steps` maps to the cc CLI's
  max-turns imperfectly. Is best-effort mapping fine, or should `loop_policy` be
  documented as authoritative only for `:shared` and advisory for `:native`?

---

## 9. Non-goals

- Not changing Layer A (executor) or the CapBAC model.
- Not changing cc's / codex's loop runtime (option b).
- Not building streaming / token-by-token output.
- Not fixing the `:sync_result` ordering limitation in Phase 1–2 (Phase 3).
- Not adding new flavors beyond the one DeepSeek tool-use proof flavor (Phase 1).
