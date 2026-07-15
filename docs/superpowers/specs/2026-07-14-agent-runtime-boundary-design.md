# AgentRuntime Boundary Design

**Date:** 2026-07-14

**Status:** Approved direction — domain-agent narrow facade

**Owner:** gagameow

**Decision:** Use a command-shaped facade now; do not introduce a Command/Port framework.

## 1. Problem

`ezagent_domain_session` currently mixes two responsibilities:

- the Session conversation plane: membership, routing, delivery, declarations and
  session teardown intent;
- parts of the Agent control plane: agent materialization, cold rehydration,
  executor lifecycle, sandbox destruction and runtime-status reads.

The coupling previously allowed session creation or delivery to block on an agent
transport and makes Session code responsible for details owned by agent and flavor
runtimes. The existing `session_create_no_agent_spawn` gate protects only the create
transaction. It does not close delivery, teardown, orchestrator tools or other
Session-domain lifecycle paths.

## 2. Constraints

1. Core contains primitives only and cannot acquire Agent/Session domain vocabulary.
2. `Ezagent.LocalRuntime` remains URI-only, owner-gated and Kind/flavor-agnostic.
3. `ezagent_domain_session` may depend on `ezagent_domain_agent`; the reverse edge is
   forbidden to avoid a cycle.
4. Plugins continue to own flavor execution mechanics and cannot become compile-time
   dependencies of domain-agent.
5. Invocation/Lifecycle remains the platform command/effect grammar. This design
   does not create a parallel command bus.
6. CapBAC, workspace ownership and audit semantics may not be weakened by a facade.
7. The first gate must distinguish lifecycle ownership from legal membership,
   routing, dispatch and non-activating reads.
8. Existing debt must be visible and driven down; a broad path exemption is not
   acceptable.
9. PR #1375 makes the target Agent's Manage cap the authority for PTY read, write
   and restart. PTY access policy remains owned by `Ezagent.Domain.Pty.Access`; the
   Agent control facade must not duplicate it.
10. PR #1379 requires statically resolvable `users.caps_json` issuance paths to use
    `Ezagent.Cap.issue/3`, but it does not prove the runtime property that every
    stored capability was issued there; PR #1381 makes that scanner boundary
    explicit, including the `Module.concat/1` blind spot. Any future facade
    capability issuance must still use `Ezagent.Cap.issue/3` and may not parse and
    store provenance-bearing capabilities directly. PR #1382 accepted that runtime
    guarantee as Phase-4 Ed25519 signing: `issue/3` signs the artifact and every
    reviewed STORE/LOAD boundary verifies it. The Agent facade must wait for that
    mechanism rather than inventing an ETS fingerprint side channel.

## 3. Vocabulary and ownership

| Plane | Owner | Meaning |
|---|---|---|
| Agent definition plane | domain-agent + definition data | Recipe, Flavor and AgentTemplate describe the desired agent. |
| Agent control plane | `ezagent_domain_agent` | Materialize, ensure deliverable, readiness, restart, retire/destroy and credential/config application. |
| Agent execution adapter | flavor plugin/domain sidecar | cc/codex/py/native OS process, bridge and protocol mechanics. |
| Session conversation plane | `ezagent_domain_session` | Membership, declarations, routing, message delivery and session lifecycle. |
| Core Kind locality plane | `ezagent_core` | Owner-gated liveness/spawn/rehydration primitives without Agent semantics. |

`AgentRuntime` is the name of the control-plane boundary, not a requirement to create
a module or GenServer named `Ezagent.AgentRuntime`.

## 4. Chosen architecture

### 4.1 Narrow domain-agent facade

Session expresses intent through a small public facade owned by domain-agent. The
facade hides `SpawnRegistry`, `KindRegistry`, executor/sidecar selection and flavor
modules.

Candidate semantic API:

```elixir
@spec materialize_declared_member(materialization_request()) ::
        {:ok, agent_ref()} | {:error, reason()}

@spec ensure_deliverable(agent_ref(), delivery_context()) ::
        {:ok, :live | :rehydrated} | {:error, reason()}

@spec retire_spawned_member(agent_ref(), retirement_context()) ::
        :ok | {:error, reason()}
```

The implementation plan must validate final names against the existing
`Ezagent.Domain.Agent` facade before creating modules. The preferred move is to
relocate/deepen the existing facade rather than create a competing manager.

### 4.2 Command-shaped, not a Command framework

Each API:

- names an agent-domain intent;
- accepts explicit caller/workspace/authority context where required;
- returns tagged tuples;
- delegates authorization to existing CapBAC chokepoints;
- uses existing Invocation/Lifecycle and runtime primitives internally.

It does not add command structs, a port behaviour, a port registry or plugin control
adapters. Those abstractions become eligible only after at least two independent
runtime-controller implementations exist and the existing Invocation/Lifecycle
grammar is shown insufficient.

The facade also does not become a second PTY policy owner. PTY output/input access
continues through `Ezagent.Domain.Pty.Access` and `Ezagent.ActionSet.Pty`; Agent
control orchestration may call those sanctioned surfaces but may not reproduce their
Manage-cap checks.

### 4.3 Existing facade correction

`Ezagent.Domain.Agent` currently lives under `ezagent_domain_session` even though the
Agent Kind and agent vocabulary now live in `ezagent_domain_agent`. Its lifecycle,
config, sandbox and credential reads are evidence that the facade concept already
exists, but its app ownership and moduledoc are stale.

The migration design is:

1. establish the domain-agent-owned facade and its public read/control contract;
2. repoint consumers;
3. remove the Session-owned module rather than retain a compatibility shim;
4. then ratchet Session lifecycle crossings downward.

No-back-compat policy means the repository must not keep two permanent facade homes.

## 5. Dependency matrix

| From | To | Decision |
|---|---|---|
| core | domain-agent/session/plugin | Deny. |
| domain-agent | core + identity + agent-bridge | Allow; domain-agent remains a leaf and uses runtime-optional probes for flavor domains. |
| domain-agent | domain-session | Deny; prevents cycle and ownership reversal. |
| domain-agent | flavor plugin at compile time | Deny; use existing registration/contracts/data. |
| domain-session | domain-agent public facade | Allow. |
| domain-session | Agent spawn/config/credential/sandbox internals | Deny. |
| domain-session | core Router/Invocation/URI | Allow. |
| domain-session | member business dispatch | Allow. |
| plugin flavor | domain-agent extension contract + core runtime | Allow. |
| plugin flavor | Session internals | Deny. |

## 6. Session allow/deny semantics

### Allowed

- declare and persist a session member or desired role slot;
- route and deliver messages through existing dispatch semantics;
- request materialization/rehydration/retirement through the domain-agent facade;
- read membership state;
- use a cap-gated, non-activating public agent read API;
- destroy the Session or SessionTemplate itself.

### Forbidden

- direct `Ezagent.Entity.Agent.spawn_from_*` calls;
- direct agent-targeted `SpawnRegistry.spawn*` or `ensure_live` decisions;
- direct Agent executor/sidecar start/stop from Session; the Session-owned
  `SessionManager` conversation executor remains legal even though its binding key
  is an orchestrator URI;
- direct agent-targeted `Ezagent.Lifecycle.destroy` fallback;
- direct Agent Sandbox/config/credential application;
- direct flavor plugin runtime calls;
- wrapper functions in Session whose only purpose is to conceal one of the above.

### 6.1 Locked follow-up decisions (2026-07-15)

`Ezagent.Session.SessionManager` owns the Session conversation executor: its
binding contains an orchestrator URI, but it does not start, stop or own the Agent
Kind, PTY or flavor sidecar. Exact `SessionManager.ensure_started/1` and `stop/1`
seams are therefore legal Session lifecycle and must be pinned by narrow positive
and negative scanner fixtures rather than hidden behind a domain-agent facade.

Session code must not call `Ezagent.Lifecycle.destroy/2` for Agent targets.
Domain-agent will expose a provenance-gated retirement operation. Session retains
the policy decision and sequencing (membership, lineage and teardown reason), while
domain-agent validates the supplied provenance, performs authorized cleanup, and
may use VM-internal termination only as an explicit last resort. A last-resort
termination returns structured partial success, emits telemetry/audit evidence and
creates a durable cleanup obligation; it never converts incomplete cleanup into
unconditional success.

### 6.2 Retirement contract amendment (review closure, 2026-07-15)

Retirement separates four facts that must never be conflated:

1. **authority** — the authenticated caller and caps may request destruction;
2. **provenance** — the target belongs to the supplied creation/session root;
3. **termination** — the Agent process and durable Kind state are gone;
4. **cleanup** — filesystem, binding, lineage and sidecar resources are reconciled.

Lineage is evidence of provenance, never authorization. The normal path carries an
explicit retirement context with `caller`, `caps`, `workspace_uri`,
`provenance_root`, creation-attempt identity and reason. It verifies an Agent target,
workspace consistency and transaction-owned provenance, then uses the existing
Sandbox destroy dispatch so CapBAC remains at its sanctioned chokepoint. A caller
that passes provenance but lacks authority is denied.

Rollback receives the trusted provenance root and created-Agent inventory from the
creation attempt. It must not derive the proof root from the target's own lineage
row. A target absent from that inventory, under another root or in another workspace
is never retirement-eligible for that rollback.

Retirement returns one of:

```elixir
{:ok, %{termination: :destroyed, cleanup: :complete}}
{:partial, %{termination: :destroyed, cleanup: :pending, obligation_id: id, failures: failures}}
{:error, %{termination: :not_destroyed, reason: reason}}
```

Session callers preserve these distinctions. They may remove binding/lineage only
after complete cleanup, or after every remaining step has been durably captured by
an obligation that retains the evidence required to retry it. An error without such
an obligation leaves binding and lineage intact. Cascade teardown aggregates and
surfaces partial/error reports instead of converting them to unconditional `:ok`.

### 6.3 Durable retirement obligations

Retirement cleanup uses a dedicated durable store, not the invocation DLQ. Each
obligation records the Agent, workspace, provenance root, creation attempt, reason,
pending steps, status, attempts, last error and timestamps. Status transitions are
`pending -> running -> resolved`, with retry exhaustion represented as `failed`.
Creation is idempotent for the same Agent/creation-attempt/retirement reason.

A sweeper and an explicit operator retry surface execute pending steps and persist
attempt/error state. Successful reconciliation marks the obligation resolved before
discarding its remaining provenance evidence. Telemetry covers obligation creation,
attempt, resolution and failure; the durable obligation itself is the audit and
recovery record. A DB-write failure cannot be described as partial success: either
termination has not occurred and the evidence remains intact, or an alternate
durable record is committed before an irreversible fallback.

### 6.4 Precise SessionManager classification

The scanner recognizes only the inventory-backed conversation-executor shapes as
legal `SessionManager.ensure_started/1` and `stop/1` seams. Positive fixtures pin
those bindings; negative fixtures prove ordinary worker/member/PTY/sidecar lifecycle
control is still classified. The scanner must not become blind to every
`SessionManager` call merely because the module is Session-owned.

## 7. Static gate

### 7.1 Placement

Create a standalone architecture test:

`apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs`

The gate is repository architecture policy, so the core architecture suite is the
appropriate enforcement home. It must not introduce a runtime Agent abstraction in
core.

### 7.2 Scope

Scan every production Elixir source under:

`apps/ezagent_domain_session/lib/**/*.ex`

The file list must be discovered dynamically so new Session files cannot escape the
gate.

### 7.3 Classifier

Use `Code.string_to_quoted!/2` plus an AST walk. Resolve:

- fully qualified remote calls;
- calls through module aliases;
- the initial closed family of lifecycle functions;
- call metadata sufficient to report file, line, resolved module/function and class.

Do not claim general dataflow analysis. Generic calls such as `Lifecycle.destroy/2`
or `SpawnRegistry.spawn/1` are violations only when the API/call site is an
agent-lifecycle seam identified by the closed classifier. Legal Session lifecycle
calls must remain negative fixtures.

In particular, `SessionCreator.demand_spawn_member/1` is a mixed-target wrapper:
the current callers pass one explicit Session URI and three explicit Agent/member
URIs. ARB-1 must classify those invocation edges (or first split the wrapper into
syntactically distinct target-specific APIs); it must not infer Agent ownership
from the wrapper parameter name or mark the shared body universally forbidden.

### 7.4 Debt allowlist

Each allowance contains:

```elixir
%{
  path: "apps/ezagent_domain_session/lib/...ex",
  class: :agent_materialization,
  source_anchor: "Ezagent.Entity.Agent.spawn_from_template_content(",
  reason: "migration slice ARB-2"
}
```

Rules:

- no directory-wide exemption;
- no count-only subtraction;
- an allowance must match exactly one current offender;
- stale allowances fail the suite;
- new offenders fail even if the total count does not increase;
- the target is an empty allowlist after migration.

### 7.5 Teeth and precision fixtures

Required positive fixtures:

1. fully qualified Agent spawn;
2. aliased Agent spawn;
3. direct agent ensure-live/destroy seam;
4. a Session wrapper around a forbidden seam, if wrapper classification is included
   in v1.

Required negative fixtures:

1. Session destroy;
2. SessionTemplate spawn/rehydration;
3. membership/Kind lookup without a lifecycle decision;
4. Invocation dispatch to an existing member.

## 8. Initial inventory to classify

The implementation inventory must cover at least these current areas before the
allowlist is frozen:

- `session_creator.ex` member spawn;
- `session_creator/template_team.ex` Agent materialization;
- Session delivery cold-agent rehydration;
- Session teardown sandbox/destroy paths;
- orchestrator tools and participants materialization;
- member template materialization;
- orchestrator executor/session-manager control;
- the Session-owned `Ezagent.Domain.Agent` lifecycle/config/sandbox/credential reads.

Every hit must be classified as migrate now, allowlisted debt with an owner/slice, or
legal non-lifecycle use. An unclassified hit makes the SPEC incomplete.

The closed, source-backed inventory is recorded in
[`docs/superpowers/notes/2026-07-14-agent-runtime-boundary-inventory.md`](../notes/2026-07-14-agent-runtime-boundary-inventory.md).
It is the ARB-0 input to the ARB-1 classifier and debt allowlist. Because PR #1375
is still pending, entries in `session_creator/materializer.ex` are intentionally
marked `anchor_pending_1375`; ARB-1 must not freeze a line number or final source
anchor for those entries until that PR lands and this branch is rebased.

## 9. Credential operations are a separate track

Credential provisioning changes deployment state and is not part of the code PR.

For existing CC agents:

1. inspect normalized credential status through the authorized World detail surface;
2. prefer `claude /login` in the target agent's own Terminal/config home;
3. use `mix ezagent.demo.seed_cc_sandbox` only with a current, detail-reported target
   directory and an operator-owned credential source;
4. verify normalized status becomes `authenticated`;
5. invoke the agent through the normal product entry;
6. restart and invoke again;
7. retain only redacted evidence.

`mix ezagent.credential.adopt` establishes a default source for future cascade
materializations; it does not directly repair an existing target agent.

## 10. Error handling and security

- Expected facade failures use `{:error, reason}`; no convenience rescue may turn
  lifecycle failure into success.
- Agent retirement distinguishes complete cleanup from structured partial success;
  partial cleanup is never reported as plain `:ok`, and every partial result names
  a persisted pending obligation.
- Session receives domain-level reasons, not PID/sidecar/plugin internals.
- Workspace owner checks remain in core/runtime chokepoints.
- CapBAC checks remain at their existing sanctioned owners.
- Any capability artifact emitted by a later facade slice must come from
  `Ezagent.Cap.issue/3`; direct parser→store and hand-authored `granted_by` flows are
  forbidden.
- Missing credentials stay loud for automatic materialization.
- Credential evidence never contains content, hashes, tokens, environment dumps,
  shell tracing or guessed filesystem paths.

## 11. Delivery slices

1. **ARB-0 — SPEC and exact inventory:** freeze vocabulary, ownership and classified
   crossings.
2. **ARB-1 — Gate with current-debt allowlist:** AST classifier, positive/negative
   fixtures and stale-entry enforcement.
3. **ARB-2 — Facade ownership correction:** move/deepen existing Agent facade into
   domain-agent and repoint read consumers.
4. **ARB-3 — Materialize/ensure-live command cutover:** Session uses narrow facade;
   remove matching allowances.
5. **ARB-4 — Retire/destroy cutover:** Session teardown expresses intent; remove
   remaining lifecycle allowances.
6. **ARB-5 — Target-zero lock:** empty allowlist and adversarial review.

Today's requested implementation plan covers ARB-0 and ARB-1 as the committed task
scope. ARB-2 through ARB-5 are explicit follow-up slices; they must not be silently
claimed complete by a gate that merely allowlists all current debt.

### 11.1 Upstream PR integration strategy

PR #1375 and PR #1379 are semantic prerequisites, not branch parents:

- absorb their approved contracts into this design now;
- do not cherry-pick or merge either unreviewed PR head into this branch;
- implement line-number-independent inventory and scanner fixtures while they are
  pending;
- wait for #1375 before live creator `/login` acceptance and before freezing final
  source anchors in files it changes;
- wait for #1379 before implementing facade slices that issue or persist authority;
- after both land, rebase onto current `origin/main`, regenerate the inventory and
  run the complete gate set.

## 12. Rejected alternatives

### Generic core `Ezagent.AgentRuntime`

Rejected because core cannot own Agent vocabulary and already has the correct generic
`LocalRuntime` primitive.

### New Command/Port framework now

Rejected because it would duplicate Invocation/Lifecycle semantics without multiple
runtime-controller implementations or a proven transport/replay requirement.

### Regex/count-only gate

Rejected because comments/docs cause noise, aliases evade naive matching and a fixed
count can be gamed by replacing one old violation with one new violation.

### Blanket ban on Registry/Lifecycle from Session

Rejected because Session legitimately manages Session/SessionTemplate Kinds and must
continue routing/dispatching to members.

## 13. Acceptance criteria

- The design names one owner for every plane and creates no dependency cycle.
- The gate scans all Session production files and detects qualified and aliased
  forbidden calls.
- Legal Session lifecycle and conversation operations remain accepted.
- Every current direct Agent lifecycle crossing is classified.
- Every debt allowance is exact, justified and stale-checked.
- No generic AgentRuntime is added to core.
- No Command/Port framework is added.
- The targeted tests, architecture/invariant suites, `mix ezagent.arch.scan`,
  `mix ezagent.check_invariants` and `mix precommit` pass.
- Codex adversarial review concludes `SOUND` before lead handoff.
