# Git Provider Plan C Atomic Ownership Receipt Design

## Status and scope

This design is the approved correction to the Plan C start-ownership model. It
supersedes the creation-inventory ordering in the Plan C hardening design where
that ordering conflicts with this document.

The objective is exact: a newly created task Agent remains recoverably owned if
the caller crashes after actor creation but before Template completion, while an
existing or concurrently created Agent that this attempt merely adopts can
never become retirement-owned by that attempt.

This change does not add provider writes, private checkout, cross-node process
placement, a general distributed transaction protocol, user-authored launch
metadata, or a new plugin lifecycle. It does not weaken retirement CapBAC,
workspace scoping, URI validation, start leases, or cleanup fencing.

## Problem

`Ezagent.Workspace.TaskWorkspace.PreStart.prepare/1` currently claims the start,
then writes `CreationInventory` before checkout verification and before the
Template Class instantiates anything
(`apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex:12-23,123-128`).
That row is not an intent row: `CreationInventory.member?/4` treats it as a
retirement ownership fact (`apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory.ex:41-55`).

This creates two critical failures:

1. An `already_started` result can adopt an existing Agent after the pending
   attempt has already asserted ownership. If the existing Agent has matching
   lineage, recovery can retire an Agent the attempt did not create.
2. Moving the write after `instantiate/3` is also insufficient. A crash after
   the new child starts but before the caller records inventory leaves a newly
   created Agent with no sanctioned retirement proof.

The ownership fact must therefore be committed by the winning new child, as
part of its successful initialization, and never by a preparing caller or an
adopting loser.

## Non-goals

- Making arbitrary Template instances transactionally create arbitrary groups
  of Kinds.
- Allowing plugins, authored templates, recipes, or callers to choose ownership
  roots or creation-attempt identifiers.
- Replacing `SpawnRegistry` idempotency or changing the meaning of
  `:already_started`.
- Treating URI workspace membership as creation ownership.
- Combining PostgreSQL commit and OS-sidecar launch into one transaction.
- Relaxing the existing retirement requirement for a valid caller, caps,
  workspace, provenance, attempt, and reason.

## Current evidence

- The durable Provision row already owns the trusted start intent and allocates
  `creation_attempt_id` while holding its row lock
  (`apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex:28-72`).
- Provision has durable `:starting` and `:sidecar_started` states plus
  `agent_uri`, `creation_attempt_id`, and `provenance_root_uri`
  (`apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex:8-17,50-85`).
- Core PreStart pending claims are process-local and are deleted on caller
  `DOWN`; they are deliberately not recovery state
  (`apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex:106-146`).
- The only atomic fresh/adopted evidence is the DynamicSupervisor outcome
  preserved by `SpawnRegistry.spawn_detailed/1`
  (`apps/ezagent_core/lib/ezagent/spawn_registry.ex:146-199`).
- `LocalRuntime.ensure_started_detailed/1` is currently only a plugin-isolation
  facade over that core result (`apps/ezagent_core/lib/ezagent/local_runtime.ex:64-71`).
- The Template contract returns optional `%{fresh?: boolean()}` but accepts no
  trusted launch context (`apps/ezagent_core/lib/ezagent/kind/template.ex:31-53,56-89`).
- TemplateSpawn currently attaches the attempt only after instantiate returns,
  then records inventory after lineage, workspace, sandbox, and behavior work
  (`apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:641-654,497-524,981-1009`).
- `CreationInventory` has no pending/confirmed state; its schema contains only
  attempt, Agent, root, workspace, and timestamps
  (`apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory_entry.ex:7-22`).
- Retirement accepts inventory only together with workspace and lineage, then
  persists a retryable obligation
  (`apps/ezagent_domain_agent/lib/ezagent/agent/retirement.ex:25-34,66-96`).
- AgentLineage is durable DB state with an ETS read cache, and `record/2`
  overwrites the current parent
  (`apps/ezagent_core/lib/ezagent/agent_lineage.ex:31-59,93-115`). It cannot be
  independently written later without leaving another crash window.

## Architectural boundaries

The dependency direction is load-bearing:

```text
domain.workspace: trusted Plan C context issuer + start/recovery owner
  -> domain.agent: authority contract + validator + Agent creation transaction
       -> core: opaque launch-context transport + generic spawn mechanics
plugin: flavor materialization; transports an opaque handle through core APIs
```

Core must not depend on `Ezagent.Agent.CreationInventory`, Agent-domain schemas,
Workspace stores, lineage policy, or retirement semantics. Plugins must not
write creation inventory, lineage, workspace bindings, Provision rows, or
retirement obligations. Domain Workspace may request a trusted Agent launch,
but it may not manufacture a receipt.

The transaction belongs to a new Agent-domain module,
`Ezagent.Agent.LaunchCoordinator`. It is invoked directly from the Agent
actor's winner-only initialization path, not from `SpawnRegistry` and not from
a Template Class. It depends on the shared Repo and on Agent-domain persistence
APIs. Core only transports an opaque term; it has no callback to, compile-time
dependency on, or runtime knowledge of the coordinator.

## Opaque launch context

### Trusted source

`TaskWorkspace.AgentStart` remains the only Plan C constructor. After
`Store.bind_start_intent/2` has locked and persisted the exact Agent URI,
workspace URI, provenance root, and generated attempt id, the Workspace
PreStart implementation issues a one-use opaque launch handle through its
private claim server:

```elixir
TaskWorkspace.PreStart.issue_launch_context(%{
  creation_attempt_id: row.creation_attempt_id,
  agent_uri: agent_uri,
  provenance_root: provenance_root,
  workspace_uri: workspace_uri,
  provision_id: row.provision_id,
  generation: row.generation
})
```

The issuer re-reads and validates the durable bound intent. The returned handle
is an opaque reference/capability known only to the Workspace issuer. It is
placed in
the private `pre_start_ref` execution option, never in Template content,
Template data, recipe content, invocation args, URI query strings, snapshots,
logs, telemetry metadata, or plugin configuration.

The core PreStart result adds only `launch_context: opaque_handle`. Core does
not inspect it. TemplateSpawn passes it through a dedicated runtime option to
the Template contract. A caller-authored map cannot construct that option: the
production call sites and constructors are structurally gated, and the
registered Workspace authority resolves only handles issued for the currently
fenced Provision start claim.

The handle is not a secret credential, but it is authority-bearing and follows
secret handling rules: no serialization, inspection, persistence outside the
trusted store, or exposure to a subprocess. Its durable identity data already
lives in the Provision row; the handle is only a claim over that data.

### Minimal transport interfaces

Core introduces no receipt behavior. It treats launch context as an opaque
runtime option and carries it to the scheme-owned child specification.
Domain.agent defines a narrow dependency-inversion behavior that contains no
Git or Provision schema dependency:

```elixir
@callback resolve_launch(term(), URI.t()) ::
  {:ok, %{attempt_id: String.t(), agent_uri: URI.t(), root_uri: URI.t(),
          workspace_uri: URI.t(), issuer_ref: term()}} | {:error, term()}
@callback acknowledge_launch(issuer_ref :: term()) :: :ok | {:error, term()}
```

Domain.workspace implements and registers this authority during application
startup. Resolution re-reads the locked Provision and current start claim; it
does not consume the handle. This preserves dependency direction:
domain.workspace depends on the Agent-domain behavior, while domain.agent never
imports the Workspace Store or Provision schema. After the ownership
transaction commits, the coordinator acknowledges consumption. A crash before
acknowledgement can only replay the same exact transaction.

The runtime APIs gain option-bearing forms while retaining existing arities:

```elixir
LocalRuntime.ensure_started_detailed(uri, launch_context: handle)
SpawnRegistry.spawn_detailed(uri, launch_context: handle)
```

The registered scheme spawn function must receive a core-owned spawn request
containing the URI and opaque option. The compatibility adapter continues to
support existing arity-one functions when no launch context is present. An
arity-one registration must fail closed with `:launch_context_unsupported` if
a context is supplied; silently dropping the context would recreate the crash
gap.

Template Classes gain an explicit runtime-context form rather than embedding
the handle in authored data:

```elixir
instantiate(template_name, template_data, workspace_uri,
  launch_context: opaque_handle
)
```

The fourth argument is framework-owned. Existing `instantiate/3` remains valid
for callers with no launch context. For a trusted context, TemplateSpawn calls
only `instantiate/4`; a Template Class that cannot transport it fails before
spawn. Plugins pass the option unchanged to LocalRuntime or Kind spawn and may
not inspect, serialize, cache, replace, or consume it.

## Winner-owned Agent creation transaction

The Agent child receives the opaque handle in supervisor init arguments. The
new-child initialization path invokes `LaunchCoordinator.consume_before_start/2`
before the Kind is registered as live and before `DynamicSupervisor.start_child`
can return success.

The coordinator validates all of the following from trusted durable state:

- the handle exists, is unused, and belongs to the current fenced start claim;
- the requested URI exactly equals the bound Agent URI;
- attempt, provenance root, workspace, provision, and generation match;
- the URI is an `entity://agent/...` target and its workspace equals the bound
  workspace;
- the provenance root is in the same workspace;
- no conflicting receipt exists for the attempt and Agent.

It then runs one `Repo.transaction` that atomically persists every durable fact
retirement needs:

1. the creation inventory ownership receipt;
2. the exact direct Agent lineage parent;
3. the exact durable Agent-to-workspace coordinate in the receipt.

The inventory row's workspace column is the durable workspace ownership fact;
it is not split into a separate write. The same transaction also writes the
exact lineage row. These two rows atomically contain all durable coordinates
that retirement validates: attempt, Agent, provenance root, and workspace.

AgentLineage needs a transaction-aware exact-write function that does not
update ETS until commit. The coordinator commits inventory and lineage, then
updates or invalidates AgentLineage and WorkspaceRegistry consistency caches.
`WorkspaceRegistry` remains an ETS consistency cache; its authoritative durable
workspace value for this flow is the inventory row plus the URI's structural
workspace. Cache update failure does not undo committed truth: retirement must
rehydrate/read through the durable lineage before authorization. No retirement
decision may rely on an ETS row newer than or inconsistent with the committed
transaction.

The coordinator consumes the in-memory opaque handle only after the transaction
commits. If the node crashes first, the handle disappears. If it crashes after
commit but before consumption, an exact replay converges on the already
committed receipt; a conflicting replay fails. Thus handle consumption need not
be a third durable write and cannot create partial ownership.

This transaction is the ownership receipt. A separate cryptographic receipt is
unnecessary because it never crosses a trust boundary. The returned opaque
`receipt_ref` is used only to correlate initialization and completion; only the
database facts authorize recovery.

If validation or any durable write fails, Agent initialization returns an error.
The child never becomes live and the supervisor cannot return `:started`.

For `KindRegistry` lookup hits and concurrent `{:already_started, pid}` results,
no new child initialization runs. The handle remains unconsumed, no receipt,
lineage, or workspace fact is written, and the result is adopted with
`fresh?: false`. The caller releases/fails its start claim without retiring the
existing Agent.

## Component responsibilities

### Core

- `SpawnRegistry`: preserve atomic `:started` versus `:already_started`, carry
  runtime-only spawn options, reject unsupported context transport.
- `LocalRuntime`: remain the owner-gated plugin facade and pass options through.
- Core Template contract: define the optional runtime-context callback shape;
  never place context in authored template data.
- Core must not write or query ownership facts.

### Agent domain

- `LaunchAuthority`: define the narrow resolve/acknowledge contract implemented
  by the trusted Workspace issuer, without depending on Workspace schemas.
- `LaunchCoordinator.consume_before_start/2`: run the winner-only transaction.
- Agent actor/supervisor initialization: call `LaunchCoordinator` directly
  before registration/liveness success.
- CreationInventory and lineage persistence: expose transaction-aware exact
  inserts/updates and conflict checks; publish WorkspaceRegistry only as a
  post-commit consistency cache.
- TemplateSpawn: request trusted transport, accept fresh/adopted result, and
  verify the committed receipt on fresh completion. It must no longer create a
  Plan C receipt after instantiate.

### Workspace domain

- Own the Provision start intent, lease, generation, and recovery state.
- Construct only the trusted pre-start reference and request handle issuance.
- On successful fresh completion, verify exact committed facts and mark
  `:sidecar_started` with the current claim.
- On adopted completion, release/fail the start without touching the Agent.
- Recovery retires only when the exact committed receipt exists.

### Plugins

- Continue flavor-specific config and sidecar materialization.
- Pass the opaque runtime option unchanged into the Agent Kind start.
- Return the atomic fresh/adopted result and receipt correlation metadata.
- Never authorize ownership or persist ownership facts.

## End-to-end data flow

### Prepare

1. AgentStart binds exact retirement intent in the locked Provision row.
2. PreStart claims `ready -> starting` with a fenced lease and verifies checkout.
3. The Workspace launch authority validates the bound row and issues an opaque
   handle.
4. No creation inventory, lineage, or workspace ownership write occurs yet.

### Spawn

1. TemplateSpawn invokes `instantiate/4` with private runtime context.
2. The plugin transports the handle to LocalRuntime/SpawnRegistry.
3. Existing registry hit returns `:already_started`; nothing consumes or writes.
4. If absent, the registered spawn function starts a child with the handle.
5. During winner child init, LaunchCoordinator atomically commits the receipt
   (including workspace) and lineage, then publishes consistency caches.
6. Only after commit may init succeed and `start_child` return `:started`.
7. The plugin materializes the flavor sidecar and returns `fresh?: true` plus
   receipt correlation. Sidecar failure tears down the newly created child but
   leaves the durable receipt so recovery remains sanctioned and idempotent.

### Completion

1. For fresh success, TemplateSpawn checks the exact committed receipt and
   durable facts; it performs only remaining non-ownership obligations.
2. Workspace completion repeats exact receipt verification and fenced
   `starting -> sidecar_started` transition.
3. For adopted success, no receipt is accepted or created; completion releases
   the claim with `:sidecar_start_not_fresh`.
4. A stale completion token cannot mark success or alter ownership.

### Recovery

1. Recovery loads an expired/failed `:starting` Provision.
2. It queries the exact tuple `(attempt, Agent, root, workspace)`.
3. If the committed receipt and durable facts exist, it invokes sanctioned
   `retire_spawned` with the existing CapBAC and retirement context.
4. If no exact receipt exists, recovery must not dispatch Agent destruction;
   it cleans only the Provision-owned Git workspace.
5. Retirement and cleanup obligations remain retryable and idempotent.

## Crash windows

| Window | Durable ownership | Required recovery |
|---|---|---|
| Before start claim | None | No Agent retirement |
| After claim/handle issue, before spawn | None | Git/Provision cleanup only |
| During child init before transaction commit | None; child cannot start | No Agent retirement |
| After transaction commit, before init returns | Exact receipt + lineage + workspace | Sanctioned retirement |
| After init returns, before `start_child` returns | Exact durable facts | Sanctioned retirement |
| After `:started`, before plugin sidecar completion | Exact durable facts | Sanctioned retirement and sidecar cleanup |
| After instantiate returns, before TemplateSpawn completion | Exact durable facts | Sanctioned retirement |
| After TemplateSpawn completion, before Workspace mark_started | Exact durable facts | Sanctioned retirement |
| Any adopted/`already_started` window | No receipt for losing attempt | Never retire the existing Agent |
| After `sidecar_started` | Exact durable facts and completed Provision | Normal lifecycle retirement only |

## Concurrent attempts

Two attempts targeting the same URI may both prepare, but DynamicSupervisor
alone cannot elect the ownership winner: child initialization commits before
Kind registration makes the supervisor winner observable. The transaction
therefore fences on a unique `agent_uri` receipt key. Exactly one initialization
commits; a concurrent different attempt conflicts, its handle conveys no
ownership, and recovery must never retire the winner.

If both handles somehow reach one new child, init accepts exactly the handle in
its child spec; the coordinator's one-use claim and unique exact receipt keys
reject replay. A later retry of the winning attempt is idempotent only when all
four identity coordinates match. A different attempt cannot adopt the winning
receipt, even when Agent URI, root, and workspace happen to match.

For Plan C, an Agent URI is a permanent creation identity and has exactly one
final ownership receipt. Destroying that Agent does not make its URI reusable;
a later ownership lifecycle must use a new Agent URI. A reincarnation protocol
would require explicit receipt retirement/versioning and is outside Plan C.

## Failure, rollback, and idempotency

- Transaction failure: child init fails; no partial ownership facts and no live
  actor.
- Cache refresh failure after commit: durable facts win; cache is invalidated
  and rehydrated/read-through before authorization.
- Sidecar/config failure after actor creation: terminate best-effort, preserve
  receipt, and move the fenced Provision to recovery. Deleting the receipt here
  would recreate a crash gap.
- Post-spawn obligation failure: same sanctioned retirement path; do not
  independently forget lineage or unbind workspace before retirement resolves.
- Completion failure: return failure and retain recoverable durable ownership.
- Replay of the same handle: returns the already committed exact receipt only
  for the same child initialization identity; conflicting replay fails closed.
- Adopted result: never rolls back, reparents, rebinds, or retires the actor.
- Recovery repeats: retirement obligation uniqueness and exact attempt identity
  make repeated recovery safe.

## Migration and compatibility

The existing `agent_creation_inventory` row already represents the final
receipt and already carries the durable workspace coordinate; it needs no
pending/confirmed column. AgentLineage is already durable. The implementation
therefore needs no new table or column: it adds transaction-aware exact-write
APIs over the existing inventory and lineage schemas, and treats
WorkspaceRegistry as a post-commit consistency cache. The `agent_uri` unique
index is the transaction-level winner fence described above, not a liveness
constraint.

This branch has an explicit migration budget: `20260717004000` is the only
allowed Plan C forward migration. Nothing in this branch is integrated yet.
Therefore if implementation discovers a genuinely missing constraint, it must
revise
`apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs`
in place before integration. Do not add `05000`, do not edit older shared
`20260715001000_agent_creation_inventory.exs`, and do not rewrite a migration
after it has reached an integrated environment. If integration occurs first,
implementation must stop and request a migration-policy decision rather than
silently adding or rewriting history.

Compatibility rules:

- Existing Template `instantiate/3`, SpawnRegistry registrations, and
  LocalRuntime arities continue for non-Plan-C callers without launch context.
- A trusted Plan C context may never fall back to a context-dropping legacy
  path; unsupported classes fail closed before actor creation.
- Existing inventory rows remain valid final receipts.
- Existing Agents are not backfilled into new Plan C attempts.
- Existing completed Provision rows need no launch handle.

## CapBAC, URI, and secret constraints

- A receipt proves creation ownership only; it is not a capability. Retirement
  still requires authorized invocation context and existing retirement gates.
- Exact URI parsing uses `Ezagent.URI`; no raw string prefix, host-only, or
  caller-selected workspace comparison authorizes ownership.
- Agent and provenance root must both resolve to the bound workspace.
- Attempt ids and opaque handles cannot be accepted from invocation args,
  Template content, URI query parameters, plugin metadata, or environment.
- The launch handle must not enter logs, telemetry, snapshots, crash reports,
  OS-process argv/env, config directories, or rendered errors.
- Provider credentials, authorization headers, repository secrets, and Git
  environment remain absent from Provision and receipt schemas.
- Plugins cannot interpret the handle to mint authority or use it for a second
  Agent.

## Test matrix

1. **Winner crash before return:** kill the caller after the child transaction
   commits but before actor init/start returns; recovery finds exact facts and
   retires the Agent.
2. **Crash after instantiate:** kill after fresh instantiate returns but before
   TemplateSpawn completion; recovery retires successfully.
3. **Adopted same-lineage safety:** pre-create an Agent with the same root and
   workspace, run prepare, force `already_started`, crash, and prove the losing
   attempt has no receipt and recovery sends no destroy.
4. **Concurrent attempts:** race two distinct attempts for one URI; exactly one
   is `:started`, exactly one attempt owns a receipt, and loser recovery does not
   retire the winner.
5. **Atomic write failure:** inject failure at inventory and lineage writes;
   transaction rolls back and no actor is live. Also fail post-commit handle
   acknowledgement and prove exact replay converges without duplicate facts.
6. **Cache-after-commit failure:** fail ETS/cache publication, restart caches,
   and prove durable read-through still authorizes only the exact winner.
7. **Sidecar failure:** commit winner receipt, fail flavor materialization, and
   prove idempotent sanctioned retirement plus config cleanup.
8. **Restart recovery:** restart Repo/BEAM after receipt commit and before
   completion; rehydrated lineage/workspace plus inventory recover the Agent.
9. **Replay/conflict:** replay a consumed handle idempotently for the exact
   identity; reject changed attempt, Agent, root, workspace, provision, or
   generation without overwriting facts.
10. **Structural boundary suite:** prove core has no CreationInventory/domain
    dependency; plugins cannot call inventory, lineage, WorkspaceRegistry, or
    Provision Store; launch context has only approved constructors/call sites
    and never appears in authored/persisted/logged data.

Each crash test must use a deterministic barrier at the named boundary, not a
timing sleep. Tests assert both positive recovery and absence of destroy
dispatch for non-owned attempts.

## Rejected alternatives

### B: move Agent spawning out of plugins

Moving all Agent Kind creation into TemplateSpawn would make ownership placement
obvious, but it rewrites every flavor's Template lifecycle, sidecar rollback,
and extension materialization. It is substantially larger than the opaque
transport plus winner-init coordinator and is not required to close the defect.

### C: pending then confirmed inventory

A pending row written by prepare can protect adopted actors only if retirement
ignores it. Confirming after instantiate still loses a newly created Agent when
the caller crashes before confirmation. Adding an actor-side durable marker to
repair that gap is Plan A under another name, with an unnecessary second state.

Also rejected: a callback invoked after `start_child` returns. A crash between
the supervisor return and callback still loses ownership.

## Return and precommit boundary

This design authorizes a documentation commit only. It does not authorize
production code, tests, migrations, generated files, push, merge, rebase, or
deployment.

Implementation completion later requires:

1. the ten focused test groups above;
2. affected app tests and structural invariant tests;
3. migration review against the single-`04000` rule;
4. `mix precommit` from the umbrella root with all failures resolved;
5. a clean review showing no authored-data or plugin ownership bypass.

Baseline failures unrelated to this change must be reported with evidence and
must not be represented as passing. No implementation may be returned as
complete before fresh verification output is read.
