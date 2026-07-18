# Git Provider V1 D1: provider connection substrate

**Date:** 2026-07-18

**Status:** revised after review; awaiting written-spec approval

**Upstream:** Plans A, B, C, and D0 on `feat/git-domain-spine`

## 1. Goal

D1 adds the provider-neutral connection substrate used later by the GitHub
connection and Git adapter. It records a canonical human-owned provider
connection, owns authorization correlation and connection lifecycle, and
coordinates replaceable authorization and credential backends without exposing
provider credentials.

D1 does not authorize Git operations. `Ezagent.ActionSet.GitTaskAccess` remains
the only Git-operation authorization entry, and the five existing
`Ezagent.DomainGit.Adapter` callbacks remain unchanged.

The approved implementation shape is a split model:

- Ecto aggregates are the durable source of truth for connection identity,
  authorization attempts, versions, leases, and recovery obligations.
- ProviderConnection is an Ecto aggregate, not a live Kind. Management commands
  attach as a registered Lifecycle behavior to the existing owner User Kind,
  which owns exact receiver-bound CapBAC and reloads the aggregate for every
  transition.

## 2. Frozen upstream contracts and red lines

D1 consumes without recreating:

- Plan B's `Ezagent.DomainGit.Adapter`, `AdapterRegistry`, normalized values,
  `OperationContext`, and `GitTaskAccess` task policy;
- Plan C's public anonymous checkout, task worktrees, `project_cwd`, launch
  context, creation receipt, lineage, and workspace ownership;
- D0's `ProviderAuthorizationBackend` callbacks:
  `begin_authorization/1`, `consume_callback/1`, `reauthenticate/1`, and
  `cancel_authorization/1`;
- D0's `CredentialBackend` callbacks: `store/1`, `replace/1`, `status/1`,
  `lease_for_operation/1`, `consume_lease/1`, and `revoke/1`.

The connection lifecycle never grants repository-operation authority. A login
or social-login token is not repository consent. There is no PAT-first path,
SSH, private checkout, installation/service-token fallback, generic plaintext
decrypt API, provider HTTP, Git Data API, UI, Kanban projection, or canary in
D1.

Provider-specific endpoints, scopes, callback and token payloads, refresh and
revoke rules, permission probes, webhooks, and metadata remain plugin-owned.

## 3. Alternatives considered

### 3.1 Pure Resource Kind/Lifecycle

Rejected. It provides a natural dispatch boundary but makes snapshots an
awkward truth source for uniqueness, callback races, refresh leases, queries,
and recovery across an external credential backend. Rebuilding those concerns
beside snapshots would create a second durable model.

### 3.2 Ecto aggregate with commands on the owner User Kind

Selected. Ecto owns durable truth and concurrency. The existing canonical User
Kind is the authorized receiver for human-owned connection management. A
registered Lifecycle behavior handles commands and reloads the connection by
`connection_id` plus owner/workspace on every invocation. There is no second
live connection identity, snapshot, supervisor, or rehydration path.

### 3.3 Ecto aggregate plus a new live facade

Rejected. Live Kinds must use `entity://`; `resource://` is reserved for pure
data/filesystem resources. A new facade would add supervision and snapshot
reconciliation without adding authority beyond the existing owner User Kind.

## 4. Application and dependency boundary

Add an independent domain app:

```text
ezagent_domain_provider_connection -> ezagent_core
ezagent_domain_provider_connection -> ezagent_domain_identity

provider plugin -> ezagent_domain_provider_connection
provider plugin -> ezagent_domain_git
```

The connection domain does not depend on `ezagent_domain_git`, Workspace,
World, or any provider plugin. It depends on Identity only to register the
connection-management Lifecycle behavior on the existing User Kind.

The two domains are siblings:

- provider connection answers which exact active connection belongs to an
  owner/workspace/provider/host/execution identity;
- Domain Git authorizes and executes repository operations;
- a provider plugin consumes both contracts and owns the bridge between an
  already-authorized Git operation and an active connection.

## 5. Addressable identity and durable model

ProviderConnection has no live URI. Its immutable `connection_id` is an Ecto
aggregate identifier. Commands dispatch to the canonical owner URI:

```text
entity://<workspace>/user/<owner-id>
```

`connection_id` and `attempt_ref` are handler inputs, not capability axes. The
handler reloads them under the receiver's exact owner/workspace and rejects any
mismatch before a driver/backend effect.

All D1 tables are tenant-scoped with `workspace_uri NOT NULL` and indexed
workspace access. The minimum durable model uses four tables.

### 5.1 `provider_connections`

Fields include:

- immutable `connection_id`;
- canonical `owner_uri` and `workspace_uri`;
- closed provider-neutral `provider_id` and normalized governed host;
- immutable external account id and display-only login;
- immutable normalized execution identity;
- plugin-declared acquisition method;
- opaque authorization and credential backend refs;
- authorization and credential versions;
- status, monotonic connection version, permission digest, safe expiry facts,
  safe last-error code, and timestamps.

`display_login` is never an authorization, uniqueness, ownership, or dedupe
coordinate. After first successful binding, owner, workspace, provider, host,
external account, execution identity, and acquisition method are immutable. A
different identity creates a new connection.

Database constraints enforce uniqueness of `connection_id` and the active
binding tuple:

```text
(workspace_uri, owner_uri, provider_id, governed_host,
 external_account_id, execution_identity)
```

### 5.2 `provider_authorization_attempts`

Stores the opaque authorization ref, connection id/version, bound subject
digest, state and PKCE backend refs/digests, expiry, correlation id, monotonic
attempt version, status, and single-consumption timestamps. It never stores a
raw callback body, authorization code, state value, PKCE verifier, or token.

### 5.3 `provider_connection_operations`

A durable idempotency and recovery ledger for credential store/replace,
refresh, revoke, and disconnect. It stores operation class, correlation id,
expected versions, opaque result refs, status, lease token/deadline, safe error,
and timestamps.

### 5.4 `provider_connection_events`

An append-only secret-safe audit projection. It records actor roles, connection
coordinates, transition, versions, correlation id, result class, and safe
provider request id. It contains no sensitive backend ref that can be resolved
outside the connection domain.

## 6. Driver and backend ownership

`Ezagent.ProviderConnection.Driver` is a connection-flow contract, not another
Git adapter and not an independent provider catalog. A provider plugin declares
drivers keyed by `{provider_id, acquisition_method}`. D1 registers connection
drivers in its own registry and validates closed ids, uniqueness, and immutable
declaration fingerprints. It does not claim atomicity across that registry and
the existing Domain Git adapter registry. When a plugin declares both, a parity
gate requires the provider id and declaration fingerprint to agree; a partial
boot is unavailable and surfaced explicitly. A future production provider
plugin may add a small boot coordinator, but D1 does not create a third provider
catalog or change the Domain Git registry.

The driver owns provider-specific authorization descriptors, callback envelope
validation, external-account normalization, refresh/revoke semantics, and
non-secret metadata normalization. It cannot call Domain Git adapters or
authorize Git operations.

D1 implements the local `ProviderAuthorizationBackend`. D1 freezes and proves
the credential transaction protocol against the D0 in-process and
remote-shaped fakes. Production encrypted credential storage, key rotation,
and operation-lease implementation remain D2.

## 7. User-Kind Lifecycle command boundary

`Ezagent.ActionSet.ProviderConnection` uses `Ezagent.Lifecycle` and is registered
as a behavior on `Ezagent.Entity.User`. It adds no connection state to the User
snapshot. Every command reloads and locks the Ecto aggregate before deciding a
transition.

Initial actions are:

- `:begin_authorization`;
- `:consume_callback`;
- `:reauthorize`;
- `:refresh`;
- `:revoke`;
- `:disconnect`;
- `:read_connection`.

Every human/operator command is cap-gated to the exact owner User entity,
workspace, `:provider_connection` capability kind, ActionSet, and action.
Reauthorize, revoke, and disconnect additionally require valid, recent
assurance evidence from `ProviderAuthorizationBackend`.

The callback transport does not gain ambient authority. At begin, the owner
pre-signs an exact, expiring `:consume_callback` capability artifact and stores
it only on the authorization attempt. Callback ingress resolves the attempt,
verifies the artifact for the owner URI, and dispatches as that owner to the
owner User Kind. It may consume only that server-created attempt.
Provider callback parameters cannot select owner, workspace, connection,
provider, host, acquisition method, execution identity, or credential ref.

## 8. Connection state machine

```text
pending_authorization -> active

active -> refresh_required -> refreshing -> active

active | refresh_required | refreshing
  -> degraded
  -> expired

active | degraded | expired
  -> revoking -> revoked
  -> disconnecting -> disconnected
```

Legal transitions form a closed table. `revoked` and `disconnected` are
terminal. `revoking` and `disconnecting` immediately prohibit new credential
leases. Provider/backend failures remain in a retryable obligation state or
move to `degraded`; they never silently return to `active` or select a fallback
credential.

## 9. Authorization correlation and callback consumption

`begin_authorization` binds owner, workspace, provider, host, connection,
connection version, acquisition method, requested-permission digest, registered
redirect id, expiry, and correlation id. State and PKCE material remain behind
the authorization backend.

Callback consumption locks the attempt and performs a monotonic transition:

```text
pending -> consuming -> consumed
pending -> cancelled
pending -> expired
```

Only the first worker may hold the durable attempt claim. The claim records a
token, deadline, attempt version, and deterministic callback correlation id. A
live competing claimant observes `callback_in_progress`. After a crash or
ambiguous backend response, recovery reuses the same correlation id and exact
bound input. D0.1 returns the original logical result without repeating the
provider effect. A new correlation id after consumption receives
`callback_already_consumed`. Expired, cancelled, subject-mismatched, or stale
connection versions fail before any credential backend call.

The normalized callback result may carry credential material only as a
write-only wrapper passed immediately to `CredentialBackend`. It is never
persisted in the connection aggregate or returned to a domain/UI consumer.

## 10. Atomic credential replacement and recovery

The database and credential backend are not assumed to share a transaction.
Every store/replace uses a durable operation with deterministic correlation:

```text
prepared -> backend_committed -> connection_committed -> finalized
```

Protocol:

1. Lock the connection/version and insert or reload the deterministic
   operation.
2. Call backend store/replace with exact scope and the operation's stable
   correlation id.
3. Persist the returned opaque ref/version as `backend_committed`.
4. CAS the connection pointer/version and record `connection_committed`.
5. Finalize; enqueue the previous credential version for revoke.

Recovery rules:

- failure before backend commit leaves the current connection unchanged;
- an ambiguous backend result retries the identical D0.1 command and reconciles
  by correlation id, never by creating a new command or identity;
- backend commit without connection commit resumes the same CAS;
- if that CAS has become stale, the operation is fenced and its exact backend
  result becomes a durable cleanup obligation rather than replacing the winner;
- connection commit without old-version revoke leaves the new connection
  active and retries a durable revoke obligation;
- no path falls back to a credential belonging to another version, owner,
  workspace, provider, host, account, installation, or service identity.

## 11. Refresh lease and stale-result fencing

At most one refresh attempt owns a connection at a time. Its durable lease
contains a random lease token, connection id, base connection version, base
credential version, attempt id, and `lease_until`.

Only a result matching the current unexpired lease token and both base versions
may commit. At `now >= lease_until`, the old worker has lost authority and a new
worker may claim the operation. A stale refresh result is fenced even when the
provider call succeeded; its produced credential is compensated/revoked and
cannot overwrite the winner.

Tests use deterministic clocks and barriers at lease claim, backend commit,
connection CAS, and compensation boundaries. Timing sleeps are forbidden.

## 12. Revoke and disconnect

Revoke/disconnect first CAS the connection to `revoking`/`disconnecting`. In D1
this immediately removes the connection from selection and records a credential
generation fence. The flow then performs provider-driver revoke and
credential-backend revoke as independently recorded idempotent obligations.
Production refusal of an already-selected operation lease belongs to the D2
credential backend and adapter integration.

The connection reaches `revoked`/`disconnected` only when both obligations are
confirmed. Ambiguous results reconcile by operation correlation and backend
version. A failure is visible as a closed safe state/error and remains
retryable; the product never reports disconnected while a new credential lease
can still be issued.

## 13. GitTaskAccess prerequisite correction and D2 selection

The existing live `GitTaskAccess` receiver uses a `resource://` URI, which
violates the invariant that live Kinds are entities and resources are pure data.
D1 includes a prerequisite migration to:

```text
entity://<workspace>/worker/gta_<sha256-of-canonical-policy>
```

Its Kind pattern becomes `:entity`, while `type_name` and capability kind remain
`:git_task_access`. It remains an ephemeral non-Agent primitive created only by
`TaskAccessSupervisor.ensure_started/1`. It cannot be a caller, grantor, session
member, login principal, or token principal. The URI is derived only from the
fully validated canonical task policy, and duplicate reconciliation compares
the full policy. Git repository resources remain pure `resource://` data.

After `GitTaskAccess` authorization, a D2 provider adapter derives credential
owner, workspace, provider, host, and execution identity from the authoritative
task policy and requests the unique active connection matching those exact
coordinates. Callers cannot submit a connection id or credential ref to select
another account.

The private adapter operation then requests `lease_for_operation` with:

- the selected opaque credential ref and exact expected scope/version;
- a closed operation class;
- an opaque operation proof minted only on the authorized `GitTaskAccess`
  path;
- the existing operation correlation/idempotency coordinates.

Only the adapter's private Req function may unwrap the sensitive wrapper,
attach it to the provider request, normalize the response, and consume the
lease. The connection domain never receives Git task authority and never
returns a token.

## 14. Secret-safe events, errors, and read model

The future Plan E read model exposes only connection id, provider, governed
host, display account identity, acquisition method, execution identity, status,
versions, permission digest, safe expiry/timestamps, correlation id, and a
closed last-error code.

Closed errors distinguish invalid subject/method/host, state or PKCE mismatch,
expired/replayed/in-progress callback, correlation conflict, account conflict,
stale version, reauthentication failure, backend unavailable, credential
conflict/revocation, refresh lease loss, provider denial/protocol failure,
cleanup pending, and connection terminal state.

Raw callback values, authorization codes, tokens, refresh material, credential
wrappers, Authorization headers, provider bodies, crypto errors, environment,
paths, functions, PIDs, refs, and backend implementation details are forbidden
from structs, Inspect output, exceptions, logs, telemetry, audit, snapshots,
events, task workspaces, Agent homes, prompts, transcripts, and Kanban data.

## 15. Provider-neutral and replacement proofs

Two fake provider drivers must pass the same suite while differing in
acquisition method, metadata, refresh behavior, revoke behavior, and external
account shape. Neither fake may introduce a GitHub name, scope, endpoint, token
type, response object, installation concept, or REST path into the common app.

The D0 in-process and JSON remote-shaped authorization/credential fakes remain
conformant after the D0.1 semantic clarification, without changes to the five
Domain Git adapter callbacks, Plan C, Kanban, or connection state semantics.
Remote ambiguity cases cover failure before send, after backend commit, and
after response loss.

## 16. Implementation slices

After separate plan approval, implementation should proceed through strict TDD:

1. D0.1 conformance correction and GitTaskAccess live-entity prerequisite;
2. app boundary, closed values, migrations, and database constraints;
3. driver/backend behaviors and provider-declaration parity validation;
4. connection aggregate, legal transitions, and User-Kind Lifecycle/CapBAC path;
5. authorization claim/reconciliation and local authorization backend;
6. credential command reconciliation and pointer CAS protocol;
7. refresh fencing and revoke/disconnect obligations;
8. two-driver/two-backend conformance and secret-leak architecture gates;
9. restart/concurrency suites, full static gates, precommit, and review.

## 17. Definition of Done

D1 is complete only when all of these are proven:

1. The provider-neutral app has the dependency boundary in §4 and no GitHub or
   provider-plugin dependency.
2. Database constraints and application validation both enforce tenant, owner,
   provider, host, external-account, execution-identity, and immutable-field
   rules.
3. State/PKCE attempts expire and consume once under concurrent callbacks;
   exact correlation retries reconcile the committed result without another
   provider effect, while different-correlation replay is rejected.
4. Credential store/replace is caller-atomic and recovery covers every
   backend/DB commit window without replacing a winner.
5. Refresh leases fence stale results and compensate credentials created by a
   losing worker.
6. Revoke/disconnect is idempotent, blocks new selection before external
   effects, records the D2 lease fence, and reaches a terminal state only after
   provider and backend confirmation.
7. Every command has exact owner-User CapBAC; wrong grantee/workspace/action,
   unsigned artifact, or stale assurance creates zero driver, backend, and DB
   mutation.
8. Secret-safe structural and runtime tests cover structs, Inspect, logs,
   telemetry, audit, snapshots, errors, Agent, Plan B, Plan C, and Kanban
   surfaces.
9. Two fake drivers prove provider neutrality; local and remote-shaped D0 fakes
   prove backend replaceability and ambiguous-outcome recovery.
10. Restart tests rebuild obligations and reject stale callback, refresh,
    replace, revoke, and disconnect results using deterministic barriers.
11. Architecture gates prevent live Resource Kinds, GitTaskAccess use as a
    principal, a second Git authorization path, provider catalog drift, and
    generic plaintext retrieval.
12. Focused suites, affected app suites, `arch.scan`, `doc.scan`,
    `uri_query.scan`, `check_invariants`, lifecycle invariants, `mix precommit`,
    and PR-head CI are green, or every unrelated baseline is reproduced and
    explicitly adjudicated before completion is claimed.

## 18. Explicit deferrals

- GitHub authorization endpoints, scopes, GitHub App installation/user token
  semantics, provider Req calls, Git Data operations, and production adapter;
- production encrypted credential backend, key hierarchy/rotation, and
  deployment secrets;
- UI/routes/settings and Kanban confirmed-fact projection;
- private/authenticated checkout, SSH, PAT-first acquisition, service or
  installation-token fallback;
- Plan E canary, screenshots, real PR, CI/review/merge, deployment, or
  promotion;
- OneAuth/OneSystem runtime dependencies without a rerun of the D0 evidence
  gate and explicit lead approval;
- cc-headless MCP/credential rematerialization, AgentRuntime ARB, EntityCaps,
  `caps_json`, no-tail, bridge readiness, and #1360.

## 19. Planning gate

This document authorizes no implementation. After the user reviews and approves
this written specification, write a separate executable D1 implementation plan.
Do not combine spec approval, plan approval, and implementation into one step.
