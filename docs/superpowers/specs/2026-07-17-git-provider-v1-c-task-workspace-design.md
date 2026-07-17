# Git Provider V1-C: public task workspace provisioning

**Date:** 2026-07-17

**Status:** approved design; implementation plan not yet written

**Upstream:** Plan A transport decision and the implemented Plan B Git domain
spine

## 1. Goal

Plan C creates one isolated local Git worktree for one governed task generation
before its agent template may instantiate a subprocess. The first increment is
limited to anonymous checkout of an approved public repository.

The design closes the current ordering gap: `project_cwd` is presently template
data, and `cc_headless.agent` starts its SDK sidecar from that value without a
task-generation readiness proof. Plan C makes readiness an explicit durable fact
checked at the common template-instantiation boundary.

Plan C does not create a provider connection, call a Git provider adapter, handle
credentials, create a change request, or project Kanban state. Those remain Plans
D and E.

## 2. Evidence from the current code

- `Ezagent.Kind.Template.provision_and_instantiate/4` is the common wrapper used
  before a Template Class's `instantiate/3`; it already owns generic pre-template
  allocation ordering
  (`apps/ezagent_core/lib/ezagent/kind/template.ex:344-380`).
- `Ezagent.Template.CcHeadlessAgent.spawn_for_headless/3` starts the Agent Kind,
  materializes its config home, and then calls `ensure_sdk_sidecar/2`
  (`apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex:128-175`).
- `sdk_sidecar_params/2` passes `tmpl["cwd"]` directly to the sidecar
  (`apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex:254-285`).
- The current cc-headless validation proves only that `cwd` is a non-empty string;
  it does not prove that the directory exists or belongs to the requested task
  generation
  (`apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex:349-354`).
- `Ezagent.Sandbox.ConfigDir` already demonstrates the expected split: core owns
  safe tenant-scoped path resolution and allocation while a flavor plugin only
  materializes flavor content
  (`apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex:1-33`).
- Plan B's `Ezagent.Entity.GitTaskAccess` is the closed authoritative source for
  task id, generation, workspace, grantee, repository, provider adapter, allowed
  head ref, and idempotency inputs
  (`apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex:1-69`).
- `GitTaskAccess` validates that the repository and all actor URIs share the same
  workspace and binds task id plus generation as immutable idempotency coordinates
  (`apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex:164-176`).
- The project already has a durable recovery pattern based on a unique identity,
  row locking, a claim token, and an expiring lease in
  `Ezagent.Agent.RetirementObligations`
  (`apps/ezagent_domain_agent/lib/ezagent/agent/retirement_obligations.ex:9-33`,
  `:45-115`).

## 3. Ownership and dependency direction

### 3.1 Core owns the narrow pre-start port

Core extends the existing `Ezagent.Kind.Template.provision_and_instantiate/4`
chokepoint with a provider-neutral pre-start port. The port knows only that an
authoritative provision reference must become ready before template instantiation.
It does not know Git, GitHub, repositories, tasks, worktrees, or cc-headless.

The port is optional for ordinary templates. A template-data map without an
authoritative provision reference follows the current path unchanged. A map with
one fails closed if no implementation is registered, if the reference is invalid,
or if readiness cannot be proven.

The port returns a closed ready result containing the resolved `project_cwd` and a
single-use start claim. Core replaces the template data's `cwd` with that resolved
path before calling `instantiate/3`. Callers and plugins cannot supply a ready
result themselves.

### 3.2 Workspace Domain owns task-workspace lifecycle

`ezagent_domain_workspace` owns:

- the durable task-workspace provision record;
- the pre-start port implementation;
- tenant-scoped checkout/cache and per-generation worktree paths;
- anonymous Git subprocess execution;
- readiness, start-claim, cancellation, cleanup, and bounded recovery;
- normalized provisioning facts and blockers for later projection.

It gains a one-way dependency on `ezagent_domain_git` and consumes Plan B values.
Neither `ezagent_domain_git` nor core depends on Workspace Domain. No provider
plugin is referenced.

This placement matches the existing Workspace Domain responsibility for unified
agent provisioning while preserving the Plan B boundary that a future workspace
provisioner consumes the Git domain rather than becoming part of it
(`apps/ezagent_domain_workspace/lib/ezagent/workspace/provisioning.ex:1-6`,
`docs/superpowers/specs/2026-07-16-git-provider-v1-b-domain-spine.md:24-39`).

### 3.3 Plugins remain consumers

`ezagent_plugin_cc` receives an already resolved `cwd` and starts the SDK sidecar
as it does today. It performs no clone, worktree, provision-record, task-policy, or
cleanup operation. The same pre-start port can later gate codex or another flavor
without teaching that plugin about Git provisioning.

## 4. Frozen upstream inputs

Plan C consumes, but does not recreate:

- `Ezagent.DomainGit.RepositoryRef`, including its canonical repository URI,
  provider host, external id, owner path, base ref, and public/private visibility;
- `Ezagent.Entity.GitTaskAccess`, including task id, positive generation,
  workspace URI, exact grantee, repository binding, allowed head ref, and
  idempotency inputs;
- the exact `resource://<workspace>/git-task-access/<id>` task-access URI;
- the current signed, receiver-bound CapBAC dispatch path used to authorize the
  task Resource.

Plan C must not add a second `RepositoryRef`, task-policy struct, adapter contract,
adapter registry, provider URI scheme, or repository validator. The provision
request contains the exact task-access URI and generation assertion; the
provisioner reloads and revalidates the live authoritative Plan B policy.

Plan C does not call `AdapterRegistry` or any adapter callback. Public anonymous
checkout is local platform infrastructure. Provider API resolution and permission
facts remain behind `GitTaskAccess` for Plan D.

Plan C adds one separate, single-implementation
`Ezagent.DomainGit.WorkspaceProvisionPort` contract owned by the Git domain. This
is not a provider adapter and cannot select a provider implementation. Its only
consumer is the already-authorized `GitTaskAccess` ActionSet; Workspace Domain
registers the implementation at boot. Domain Git therefore knows the port contract
but not Workspace Domain, while Workspace Domain depends on and implements the
contract.

## 5. Durable provision identity and record

The durable identity is the tuple:

```text
workspace_uri + task_uri + generation
```

The task URI is the product task/card identity, not the `GitTaskAccess` Resource
URI. The record also stores the exact task-access URI used to load policy. A unique
database constraint on the identity prevents duplicate generations. Every
per-tenant row carries non-null `workspace_uri`.

The minimum record contains:

- `workspace_uri`, `task_uri`, and positive `generation`;
- `task_access_uri` and a deterministic provision id;
- canonical repository URI, base ref, and allowed head ref copied as immutable
  non-secret policy fingerprints after authoritative reload;
- status and monotonically increasing state version;
- cache identity, worktree identity, and canonical worktree path;
- claim token and lease deadline while an operation is running;
- single-use sidecar-start token state;
- bounded attempt count, safe blocker code, and timestamps;
- cleanup reason and completion timestamp.

Repository and branch fields are comparison fingerprints, not a second policy
source. Every retry reloads the Plan B policy and fails on drift rather than
silently updating the record.

Paths are derived by the Workspace Domain from registered tenant-scoped resource
identities. Invocation arguments never contain a caller-selected local path.

## 6. Filesystem model

### 6.1 Public repository cache

One repository/base-ref cache may be reused as read-only platform infrastructure.
Its identity is derived from the canonical repository URI plus base ref, never from
a raw clone URL. Cache mutation is serialized inside the provisioner.

The first loop may implement the cache as a bare local repository or another Git
layout selected during implementation planning. The invariant is that no agent
uses it as its working directory and no task can mutate another task's checkout.

Anonymous transport is constructed only from a validated public `RepositoryRef`.
`visibility: :private` fails with `:private_checkout_not_supported` before any Git
process or directory creation. There is no credential prompt, askpass helper,
credential helper, SSH command, environment token, or URL userinfo fallback.

### 6.2 Per-task-generation worktree

Each provision identity deterministically owns one branch name and one worktree
path. Two generations, even for the same task and repository, never share a mutable
checkout. The provisioner never uses `git stash`.

The ready proof verifies:

- the worktree directory exists beneath the expected tenant-scoped root;
- Git reports it as the expected worktree of the expected cache;
- its checked-out base/head identity matches the record;
- no other active record owns the path;
- the provision identity and current authoritative task policy still agree.

Filesystem paths and command output are not included in agent-visible blockers or
audit arguments.

## 7. State machine and compare-and-swap rules

```text
planned -> provisioning -> ready -> sidecar_started
   |            |           |             |
   +----------> blocked      +-------------+
   |                                      |
   +----------> cleanup_pending <---------+
                         |
                         v
                       cleaned
```

Allowed transitions are closed:

- `planned -> provisioning`: claim an expired/unclaimed record under row lock,
  minting a claim token and lease before filesystem effects;
- `provisioning -> ready`: only the matching claim token may commit the verified
  worktree and unused start token;
- `ready -> sidecar_started`: core consumes the start token exactly once as part of
  the pre-start claim immediately before `instantiate/3`;
- non-terminal states may move to `cleanup_pending` on cancellation or terminal
  task fact; this invalidates an unused start token in the same transaction;
- `cleanup_pending -> cleaned`: only after sidecar absence/termination is confirmed
  and the exact owned worktree is removed;
- `planned` or `provisioning` may become `blocked` with a closed safe blocker;
- a retryable blocker re-enters `provisioning` only through an explicit claim;
  unsupported/private input remains terminal for that generation.

Every state change uses a database row lock or state-version compare-and-swap. A
claim token fences filesystem completion after cancellation or lease takeover. An
expired worker cannot mark a replacement worker's result ready.

## 8. Provision and start ordering

The sanctioned flow is:

```text
governance creates/loads GitTaskAccess policy and exact task caps
  -> authorized task workflow dispatches provision for the exact task generation
  -> CapBAC rejects before provision row or filesystem effects
  -> Workspace Domain reloads and validates GitTaskAccess policy
  -> create/load planned record idempotently
  -> claim provisioning lease
  -> anonymous cache fetch/clone
  -> create and verify per-generation worktree
  -> CAS ready with unused start token
  -> agent materialization carries only the authoritative provision reference
  -> core pre-start port reloads ready record and consumes start token
  -> core injects resolved cwd and calls Template Class `instantiate/3`
  -> Workspace Domain records sidecar_started after successful instantiate
```

If `instantiate/3` fails after token consumption, core reports failure to the port.
The record moves to `cleanup_pending`; a retry does not reuse the consumed token or
assume that the prior sidecar is absent. A fresh start claim is allowed only after
cleanup/reconciliation establishes a safe state.

The `:already_started` agent path must reconcile against the same generation. It
cannot attach an existing agent/sidecar to a different provision record merely
because the agent URI matches.

## 9. Authorization and no-effect invariant

Provisioning is not an unguarded filesystem helper. The product entry dispatches to
the exact existing `GitTaskAccess` Resource using the Plan C action
`:provision_workspace`. After the ActionSet has revalidated policy and
receiver-bound authorization, it invokes the registered `WorkspaceProvisionPort`
implementation with a closed input constructed from stored policy plus `task_uri`
and `generation`. The caller cannot supply repository, provider, workspace,
grantee, branch, or local path coordinates.

The required cap is
`Capability.cap(:resource, Ezagent.ActionSet.GitTaskAccess,
:provision_workspace)` narrowed to the task-access instance and workspace. Plan C
extends the closed `GitTaskAccess` action vocabulary and policy validation with
that action; governance issues it through the existing signed ISSUE → STORE →
VERIFY path. It is not implied by a Plan B provider-operation action.

Cleanup enters through the separate `:cleanup_workspace` action on the same exact
Resource. It is granted only to the governed task-lifecycle principal, not to the
working agent by default. The ActionSet validates authority before calling the same
port. Terminal/cancel delivery uses sanctioned dispatch; neither a database watcher
nor a raw filesystem reaper is an authorization entry.

The CapBAC chokepoint must complete before:

- insertion of a provision record;
- creation of a cache/worktree directory;
- execution of `git` or any OS process;
- acquisition of a filesystem lock;
- start-token creation or sidecar interaction.

Negative tests use observable bombs to prove zero database, filesystem, Git
process, adapter, HTTP, secret-store, and sidecar effects for wrong grantee,
workspace, task-access instance, action, or unsigned/invalid artifact.

No wildcard or ambient admin fallback is permitted. Structural tests reject
`WorkspaceProvisionPort` lookup/calls outside `Ezagent.ActionSet.GitTaskAccess` and
reject direct Workspace Domain calls to a provider adapter.

## 10. Failure and blocker model

Plan C returns closed safe blockers, including at least:

- `:private_checkout_not_supported`;
- `:task_access_not_found`;
- `:task_policy_mismatch`;
- `:task_generation_closed`;
- `:repository_not_found`;
- `:base_ref_not_found`;
- `:anonymous_checkout_denied`;
- `:checkout_unavailable`;
- `:worktree_conflict`;
- `:provision_already_claimed`;
- `:provision_lease_lost`;
- `:provision_cancelled`;
- `:workspace_not_ready`;
- `:sidecar_start_already_consumed`;
- `:cleanup_incomplete`.

Errors may include a correlation id and safe attempt count. They never contain raw
Git stderr, local paths, environment, remote URL userinfo, tokens, headers, private
keys, or arbitrary provider payloads. Raw diagnostics remain operator-side with
redaction and bounded output.

Plan E may project these blockers to Kanban; Plan C does not import Kanban or move a
card.

## 11. Cleanup and first-loop recovery

The task workspace belongs to its provision record, not to the Agent's config home.
Agent sandbox destruction and worktree cleanup are separate idempotent obligations.

On task completion, cancellation, or failed start:

1. invalidate any unused start token under lock;
2. move the record to `cleanup_pending`;
3. ensure the matching generation's sidecar/agent is absent or terminated through
   sanctioned lifecycle paths;
4. verify the candidate path equals the record's canonical derived worktree path;
5. remove the Git worktree and then its remaining directory;
6. record `cleaned` only after absence is verified.

Plan C includes bounded boot reconciliation:

- reclaim `provisioning` rows whose lease expired;
- resume `cleanup_pending` rows;
- detect a ready record whose worktree proof no longer holds and move it to a safe
  blocked/cleanup state;
- never delete an unrecorded path merely because it is beneath the task root;
- never remove a worktree owned by a live, matching generation.

Periodic comprehensive reaping, workspace pooling, cross-node ownership, and
cross-node leases are deferred. The implementation must keep the record and path
layout sufficient for those later additions without claiming them now.

## 12. Alternatives considered

### 12.1 Put the provisioner in `ezagent_domain_git`

Rejected. It minimizes app wiring but mixes local filesystem/start lifecycle into
the provider-neutral operation domain and contradicts the frozen direction that the
workspace provisioner consumes Plan B.

### 12.2 Let callers provision first and pass `cwd`

Rejected. A string path is not a readiness proof. This leaves alternate template
callers able to bypass generation, authorization, idempotency, and cleanup rules.

### 12.3 Put checkout inside `ezagent_plugin_cc`

Rejected. It makes a provider-neutral platform mechanism flavor-specific, duplicates
it for the next flavor, and starts filesystem effects below the common authorization
and ordering chokepoint.

## 13. Explicit deferrals

- private or authenticated checkout;
- SSH transport, key storage, and Entity SSH Identity UI;
- GitHub OAuth, token storage, Git Data API, and change-request implementation;
- long-lived workspace pools or shared mutable working directories;
- cross-node leases and ownership transfer;
- comprehensive periodic orphan reaping and stabilization;
- Kanban/UI projection and real canary acceptance;
- cc-headless MCP assembly and credential-rematerialization readiness, which remain
  separate Plan E prerequisites.

## 14. Future build Definition of Done

The implementation plan must produce all of these proofs:

1. An authorized public task generation obtains one isolated worktree and a verified
   `project_cwd` before cc-headless SDK sidecar start.
2. A missing, blocked, private, cancelled, or mismatched provision never calls the
   Template Class's `instantiate/3`.
3. Wrong grantee/workspace/task/action and invalid signed artifacts produce zero
   provision-record, filesystem, Git-process, adapter, HTTP, secret, and sidecar
   effects.
4. Duplicate provision calls converge on one record/worktree; conflicting generation
   or policy input fails closed.
5. Concurrent start claims start at most one sidecar for a task generation.
6. Cancellation racing provisioning or startup invalidates the start claim and
   converges to cleanup without attaching a stale sidecar.
7. Terminal/cancel cleanup removes only the exact owned worktree and is idempotent;
   boot reconciliation recovers expired provisioning and cleanup obligations.
8. Private repositories fail before any credential or authenticated transport path;
   no token/key/credential reference enters agent, config dir, workspace, prompt,
   transcript, snapshot, audit, or blocker.
9. Structural gates prove `plugin_cc` contains no clone/worktree/provision-record
   implementation and the provisioner contains no adapter lookup/callback.
10. Focused tests, affected app suites, architecture/invariant scanners,
    `mix precommit`, and PR-head CI are green on a branch rebased on current main.

## 15. Planning gate

After user review approves this written spec, write a separate executable Plan C
implementation plan using strict TDD. Do not begin implementation from this design
alone.

Plan D0 research may proceed in parallel because it owns provider authorization and
credential backend replacement seams, not the public checkout/worktree files. Plans
D1/D2 must not modify the Plan C anonymous checkout boundary to smuggle credentials
into the workspace.
