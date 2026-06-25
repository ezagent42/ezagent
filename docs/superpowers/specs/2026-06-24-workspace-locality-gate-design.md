# Workspace Locality Gate Design

## Context

ezagent should not scale by simply running multiple peer BEAM nodes against the
same durable state and hoping distributed Erlang gives correct actor placement.
The current runtime relies on local `Registry`, local ETS, local
`DynamicSupervisor`, local subprocesses, and node-local session create locks.

The first scaling boundary should be workspace. Workspace already appears in
session URI shape, persisted snapshots/messages/resources, authz checks, and
session creation. What is missing is an explicit runtime contract that says
which runtime is allowed to handle live state for a workspace.

This design adds that contract without adding distributed BEAM behavior. The
first implementation must preserve single-node behavior while adding enforce
tests that simulate a non-owner runtime.

## Goals

- Make workspace ownership explicit before workspace-bound dispatch, spawn, or
  session materialization.
- Preserve existing behavior by default: the local resolver says the current
  runtime owns every workspace.
- Add enforce tests with a fake resolver so future changes cannot introduce new
  local-only assumptions unnoticed.
- Expose existing local-only assumptions through structured gate violations and
  architecture tests.
- Keep plugin authors on approved core runtime APIs instead of direct local pid
  or registry manipulation.
- Use `remove-localization-assumption` as the integration target branch for the
  implementation PRs, then return that branch back to lead via dev-together.

## Non-Goals

- Do not add a new Kind abstraction.
- Do not add Horde, Swarm, libcluster, or distributed process placement.
- Do not start multiple BEAM nodes in tests.
- Do not implement remote dispatch, edge redirects, lease takeover, heartbeat,
  or failover.
- Do not move ETS/Registry state into the database.
- Do not split one workspace across multiple runtimes.
- Do not change production behavior in the default local-owner configuration.

## Branch And PR Workflow

The work is split into two PRs. Both PRs target the integration branch
`remove-localization-assumption`, not `main`.

1. Create `remove-localization-assumption` from the latest `origin/main`.
2. PR 1 targets `remove-localization-assumption` and implements the runtime
   owner contract plus core dispatch/spawn/session gates.
3. PR 2 targets `remove-localization-assumption` and implements plugin contract
   coverage plus architecture invariants.
4. After both PRs are merged into `remove-localization-assumption`, return that
   branch to lead using the dev-together return workflow. The return must
   include branch state, validation, covered gates, exposed local assumptions,
   and remaining risks.

## Design Choice

Use a behavior-preserving gate API plus injectable owner resolver. This is the
smallest design that creates a real invariant without pretending the runtime is
distributed.

Rejected alternatives:

- Observe-only audit: lower risk, but it does not prevent future bypasses.
- Durable placement table in the first PR: closer to the final architecture,
  but it pulls in migrations, lease epochs, heartbeat, takeover semantics, and
  stale-owner write protection before the gate contract exists.

## Runtime Modules

Add three runtime modules in core.

### `Ezagent.RuntimeIdentity`

Returns the current runtime identity.

The first implementation should avoid hard-coding business logic to `node()`.
It may derive the identity from config or environment, with a node-based
fallback for local development.

Tests must be able to override the current identity.

### `Ezagent.WorkspacePlacement`

Resolves workspace ownership.

The default resolver is local:

```text
owner_of(workspace_uri) -> {:ok, RuntimeIdentity.current()}
```

Tests use a fake resolver:

```text
workspace://team-a owner = "node-a"
current runtime = "node-b"
```

The first implementation does not create a database table. A future phase may
replace the resolver with durable placement records containing owner, epoch,
status, and heartbeat metadata.

### `Ezagent.WorkspaceOwnerGate`

Central gate for workspace-bound operations.

API shape:

```text
assert_local_owner(workspace_uri, operation)
```

Return values:

```text
:ok
{:error, {:not_workspace_owner, workspace_uri, expected_owner, current_runtime, operation}}
{:error, {:workspace_owner_unknown, workspace_uri, operation}}
{:error, {:workspace_required, operation, input}}
{:error, {:workspace_gate_exemption_denied, operation, reason}}
```

Operations are structured values used for audit and test diagnostics:

```text
{:dispatch, target_uri}
{:spawn, kind_uri}
{:session_create, session_uri}
{:session_repair, session_uri}
{:plugin_ingress, adapter, external_id}
{:mcp_join, orchestrator_uri}
{:resource_access, resource_uri}
```

The gate supports two modes:

- `:enforce`: non-owner or unknown owner fails closed.
- `:observe`: non-owner or unknown owner emits a violation and continues.

The default local resolver preserves current behavior. Enforce behavior is
validated through fake resolver tests.

## Three-Layer Defense

### Layer 1: Core Chokepoint Gate

Core must gate before local assumptions can take effect.

Dispatch path:

```text
Invocation.dispatch(invocation)
  -> derive workspace_uri from target/caller/context
  -> WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:dispatch, target_uri})
  -> local KindRegistry lookup
  -> local cold spawn only if owner gate passed
  -> local GenServer.call/cast
```

Spawn path:

```text
SpawnRegistry.spawn(uri)
  -> derive workspace_uri
  -> WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:spawn, uri})
  -> existing spawn function lookup
  -> start Kind locally
```

Session create/repair path:

```text
SessionCreator.create_session(...)
  -> derive required workspace_uri
  -> WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:session_create, session_uri})
  -> existing node-local lock
  -> materialize template/team/orchestrator/session manager
```

The existing node-local lock remains an owner-runtime-internal lock. It is not
a cross-runtime correctness mechanism.

Other ingress paths should be gated where workspace can be derived reliably:

- orchestrator MCP bridge join before binding live bridge state;
- upload/download/resource access before local file/resource side effects;
- external callback paths before dispatching into session or agent behavior.

### Layer 2: Plugin Contract

Plugin workspace-bound side effects must go through owner-gated core APIs.

Plugin code must not:

- use local `KindRegistry` lookup to decide actor existence;
- directly `GenServer.call` or `GenServer.cast` a workspace-bound Kind pid;
- bypass `Invocation.dispatch/1` for workspace-bound actions;
- cold-spawn workspace-bound Kinds directly;
- fallback to a local default workspace when external ingress cannot resolve a
  workspace;
- use plugin-local ETS or subprocess state for workspaces the runtime does not
  own.

Plugin external ingress must:

- resolve `workspace_uri` from binding, session, agent, resource, or adapter
  state;
- enter an owner-gated core path before dispatch/spawn/session/resource side
  effects;
- return structured error, retry, or dead-letter on unresolved workspace rather
  than silently processing locally.

The goal is not to make every plugin remember to check ownership manually. The
goal is to make workspace-bound side effects impossible without going through a
core contract.

### Layer 3: Architecture Invariant Tests

Add structural tests to prevent future bypasses, especially in plugin apps.

The tests should scan plugin apps for:

- direct `Ezagent.KindRegistry.lookup/1` usage;
- direct `Registry.lookup(Ezagent.KindRegistry, ...)` usage;
- direct low-level spawn API usage outside approved wrappers;
- sensitive direct `GenServer.call/cast` combinations against workspace-bound
  pids;
- external ingress modules without an owner-gated core path or explicit audit
  exception.

Whitelists are allowed only when centralized and documented with a reason. A
whitelist entry must say why the path is system-global or already owner-gated.

## Exemptions

Some operations are intentionally not workspace-bound. Exemptions must be
centralized, structured, and auditable. They must not be scattered as ad hoc
`if system?` skips.

Example API:

```text
Ezagent.WorkspaceOwnerGate.Exemptions.allowed?(operation)
```

Example entry:

```text
%{
  operation: {:plugin_boot, :ezagent_plugin_cc},
  scope: :system_global,
  side_effects: :metadata_only,
  reason: "registers plugin metadata before workspace-bound actors exist"
}
```

Allowed exemption classes:

- system boot and plugin metadata registration;
- health checks and metrics;
- system-global capability or behavior metadata reads;
- workspace creation before placement exists, through a dedicated bootstrap
  contract;
- read-only static template or manifest catalog loads that do not materialize
  workspace state.

Exemptions must not cover any workspace-bound side effect such as Kind spawn,
dispatch action, session/resource/message write, or orchestrator bridge binding.

## Workspace Extraction Rules

Gate callers should pass an explicit `workspace_uri` whenever available. The
gate should not infer business semantics by guessing.

Approved extraction sources include:

- session URI workspace segment;
- entity URI host when the entity is workspace-scoped;
- resource/upload binding metadata;
- external binding rows that map external channel/account to session/workspace;
- explicit workspace parameter in create/session APIs.

If a path is clearly workspace-bound but cannot derive workspace, enforce mode
returns `{:error, {:workspace_required, operation, input}}`.

Truly system-global operations require explicit exemption.

## Telemetry And Audit

Gate violations must emit:

```text
[:ezagent, :workspace_owner_gate, :violation]
```

Metadata:

```text
workspace_uri
operation
mode
expected_owner
current_runtime
target_uri
caller_module
caller_function
result
```

Optional debug check events may exist but should be disabled by default to
avoid noisy logs.

## Testing

### Unit Tests

- default resolver returns current runtime;
- fake resolver returns remote owner;
- owner match in enforce mode returns `:ok`;
- owner mismatch in enforce mode returns structured error;
- owner mismatch in observe mode emits violation and returns `:ok`;
- unknown owner in enforce mode returns structured error;
- exemption allowed and denied paths behave as specified.

### Integration Tests

- non-owner `Invocation.dispatch/1` fails before local lookup or cold spawn;
- non-owner `SpawnRegistry.spawn/1` does not start a Kind;
- non-owner `SessionCreator.create_session` does not create session Kind,
  orchestrator Kind, SessionManager, MCP registry residue, or other live state;
- default local-owner resolver preserves existing happy paths;
- observe mode records violations and continues for audit tests.

### Architecture Tests

- plugin apps cannot directly depend on local KindRegistry decisions;
- plugin apps cannot bypass approved spawn/dispatch wrappers;
- plugin external ingress has owner-gate coverage or a centralized audit
  exception;
- whitelist failures point developers at the approved wrapper/core API.

## Implementation Slices

### PR 1: Core Locality Gate

Target branch: `remove-localization-assumption`.

Scope:

- `RuntimeIdentity`;
- `WorkspacePlacement`;
- `WorkspaceOwnerGate`;
- local default resolver;
- fake/test resolver support;
- exemption registry;
- dispatch gate;
- spawn gate;
- session create/repair gate;
- unit and integration tests for default local-owner plus fake non-owner.

Acceptance criteria:

- no production behavior change in default config;
- fake non-owner dispatch fails before local lookup/cold spawn;
- fake non-owner spawn does not start Kind;
- fake non-owner session create does not materialize live state;
- no new Kind abstraction;
- no distributed BEAM dependency.

### PR 2: Plugin Contract And Invariants

Target branch: `remove-localization-assumption`.

Scope:

- plugin contract documentation;
- architecture invariant tests for plugin bypass patterns;
- centralized whitelist/exemption reasons;
- owner-gate coverage or explicit audit exceptions for cc, codex, Feishu,
  email, external mirror, and similar external ingress paths;
- uncovered ingress list if a path is intentionally deferred.

Acceptance criteria:

- future plugin changes cannot easily bypass owner gate;
- whitelist entries are centralized and reasoned;
- architecture failure messages identify approved core APIs;
- uncovered ingress paths are documented as follow-up work, not silently skipped.

## Final Return

After both PRs land into `remove-localization-assumption`, prepare a
dev-together return for lead. The return must include:

- branch and PR state;
- exact validation run and results;
- core gates implemented;
- plugin invariants implemented;
- existing local assumptions exposed by tests/audit;
- uncovered or deferred ingress paths;
- recommendation for the next phase, likely durable workspace placement with
  owner epoch and heartbeat.

## Open Risks

- Workspace extraction may be inconsistent across legacy URI shapes.
- Some plugin ingress paths may not have enough metadata to resolve workspace
  without additional binding queries.
- Architecture tests may initially surface existing direct local registry or
  pid usage that needs triage.
- Observe mode can become a permanent bypass if not paired with enforce tests
  and explicit acceptance criteria.

## Design Review Checklist

- No new Kind abstraction is introduced.
- Default local-owner behavior preserves current single-node runtime behavior.
- Non-owner behavior is tested through fake resolver, not real distributed BEAM.
- Core chokepoints fail closed in enforce mode.
- Plugin bypasses are covered by contract and architecture tests.
- Exemptions are centralized, reasoned, and limited to non-workspace-bound
  operations.
- Both implementation PRs target `remove-localization-assumption`.
- Final handoff uses dev-together return after the integration branch is ready
  for lead review.
