# Orchestrator-MCP via a SessionManager Kind (Decision C)

> Allen chose **C** (2026-06-13) after Decision D (re-entrant in-process
> dispatch) hit 13 codex rounds of fundamental runtime friction (the GenServer
> model installs state only at callback return + runs deferred via post-callback
> mailbox, so "run the rich session-mutating tools IN the Session Kind's own
> process" cannot be made correct without layering patches onto the dispatch
> core). C runs the tools in a SEPARATE process — modeled as a Kind
> (`SessionManager`, Allen's call) — so every session mutation is a normal
> cross-process dispatch (today's battle-tested machinery), no runtime-core
> change, no handler refactor. The full D analysis is preserved in
> `2026-06-13-reentrant-self-dispatch-design.md` (the (a) cap-checked-in-process
> general primitive is split out as an orthogonal optional backlog item — task #56).

## 1. The split (OQ-2, finally clean)
- **Transport → cc plugin** (already relocated by the PR-8 transport commits,
  KEEP): `Ezagent.Orchestrator.McpChannel` / `McpSocket` / `McpRegistry` /
  `LiveJoinRegistry` / `CcOrchestratorSeed` / `orchestrator_bridge.py`. cc is
  PURE transport: the MCP socket authenticates the orchestrator (bridge token)
  and forwards `tools/call` carrying ONLY the orchestrator's caller URI + the
  decoded tool + args. cc holds NO authority.
- **Executor + operations → session domain**, as a **`SessionManager` Kind**.
- `Ezagent.Orchestrator.Tools` (the 7 tool operations) STAY in the session
  domain, **UNCHANGED** (see §4 — this is the big win over D).

## 2. The `SessionManager` Kind
A Kind (one instance per orchestrator-bearing session) whose job is to EXECUTE
the orchestrator's management tools against its session. It is the spiritual
successor of today's per-orchestrator `Ezagent.Orchestrator.McpServer` GenServer
— which ALREADY ran the tools in its own process and dispatched to the Session
cross-process (never deadlocked). C just (a) models it as a first-class Kind
(lifecycle/dispatch/snapshot, idiomatic RBK) and (b) reconstructs caps
session-side instead of in cc.

- **URI / identity:** one per session, derived from the session URI (e.g.
  `session-manager://<ws>/<session-name>` or a `session://…` sub-URI — settle in
  the plan; it must be stable + addressable by the cc transport forward).
- **Lifecycle:** spawned when the session's orchestrator is materialized
  (alongside the existing orchestrator setup in `SessionCreator` /
  `CcOrchestratorSeed`), terminated with the session. Slice: near-stateless — it
  may cache the binding (`orchestrator_uri`, `session_uri`, `workspace_uri`,
  `parent_template_uri`) it needs, or reconstruct per call (the McpServer
  `from_orchestrator_uri/1` logic moves here).
- **Behavior / actions:** the orchestration tools as dispatchable actions (reuse
  the existing `Orchestrator.Tools` impl behind them) — one `run_tool` action
  carrying `{tool, args}`, or one action per tool. The handler:
  1. **Structural authz (fail-closed):** the caller URI MUST equal this
     session's stored `orchestrator_uri` (the durable working-copy field). An
     arbitrary caller / another session's orchestrator is DENIED. (This is the
     sound structural check from the earlier O-4 attempt — it survives.)
  2. **Reconstruct the orchestrator's 4 delegated caps SESSION-side** (the
     existing `load_orchestrator_caps` privileged read of the orchestrator
     agent's `:identity` slice — runs HERE, in the session domain, not in cc).
  3. **Run the tool** via `Orchestrator.Tools.<tool>` under those reconstructed
     caps. The tool's session mutations (`chat.join`, `routing.add_rule`,
     `chat.set_prompt_templates`) dispatch to the **Session Kind cross-process**
     (SessionManager ≠ Session → no self-call), each a complete normal dispatch
     (own callback / commit / SliceChange / deferred / error handling — TODAY's
     machinery, untouched). Cross-Kind ops (worker-agent spawn) are cross-process
     as today.
  4. **Return the result;** cc encodes it into the MCP `tools/call` response.

## 3. Why C has none of D's problems
- **No deadlock:** the tools run in SessionManager's process and dispatch to the
  Session cross-process — exactly as the old McpServer did. `GenServer.call(self)`
  never happens.
- **No callback-model fight:** each session mutation commits in the SESSION
  Kind's OWN callback (its own commit/deferred/error path). SessionManager just
  makes sequential cross-process calls. None of D's "multiple per-sub commits in
  one callback / mid-callback state install / deferred mailbox / state-rebase"
  issues exist.
- **No handler refactor:** `chat.join` / `routing.add_rule`'s rich imperative
  bodies run in the Session Kind exactly as today (they're invoked via normal
  dispatch from a different process).
- **Plugin isolation (North Star) satisfied:** cc carries only the caller URI
  (no caps, no authority); authority is reconstructed + execution happens in the
  session domain (SessionManager).

## 4. Reuse — what does NOT change (the win)
- `Ezagent.Orchestrator.Tools` (+ `tools/*`): UNCHANGED. They already assume
  running in a process SEPARATE from the Session (they dispatch to it). In D they
  broke because we tried to run them IN the Session; in C they run in
  SessionManager exactly as they ran in McpServer. **No `:sys.get_state`/self-read
  rework, no deferred-spawn rework** (those were D-only problems — the reads are
  cross-process here, fine).
- The transport relocation to cc (PR-8 commits): KEEP.
- The cap-reconstruction (`load_orchestrator_caps`) + ctx-build
  (`from_orchestrator_uri`): MOVE from cc McpServer into SessionManager (session
  domain) — small relocation, same logic.
- The structural caller-is-orchestrator check: from the O-4 attempt, KEEP.

## 5. cc side (thin transport)
`McpSocket`/`McpServer` request plumbing in cc: decode `tools/call` →
`Invocation.dispatch` to the SessionManager Kind URI (carrying caller =
orchestrator URI, no caps) → encode the returned result into the MCP response.
`McpServer` keeps ONLY decode + forward + encode (no tool execution, no cap
reconstruction). cc → session is a runtime dispatch edge (not a compile dep);
cc → im is already an allowed compile dep for the SessionManager URI module if
needed (or address it purely by URI string to avoid even that).

## 6. Tests (regression net)
The existing orchestrator auth-net tests are the gate (they assert the cap
behavior that MUST be preserved): no-`admin_caps`-fallback denial, cap-#2
happy/deny, cross-orchestrator deny, per-kind list, + the O-4 structural-deny
(caller ≠ session's orchestrator → denied). Plus: (1) a full `tools/call` →
SessionManager → Session round-trip for a representative tool (e.g.
`add_managed_member`) proving the member is added + the worker spawned, no
deadlock; (2) the relay scenario (scenario_34) still green; (3) cc carries no
caps (transport-only) — assert the forwarded dispatch ctx has empty caps.

## 7. Plan / sequencing
1. SessionManager Kind: URI scheme + lifecycle (spawn at orchestrator setup,
   terminate with session) + the `run_tool` action (structural check + cap
   reconstruct + `Tools.<tool>`). Register against its Kind at boot.
2. cc McpServer/Socket: thin to decode → dispatch(SessionManager) → encode.
3. Remove the deadlocking O-4 attempt (the in-Session-Kind `OrchestratorTools`
   behavior + `ToolRunner`) from the PR-8 branch.
4. Verify: compile no-cycle, 3 gates (force-compile), the auth-net tests +
   scenario_34 + the round-trip + cc-empty-caps tests, zero-new-failures.
5. codex-adversarial-review → admin-merge (this closes PR-8 / #750 properly).
