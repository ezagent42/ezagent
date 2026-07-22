# Git Provider V1 D0 Backend Decision

**Status:** closed on 2026-07-17 at ezagent revision `d6021550b`.

## Decision

Git Provider V1 uses a **local V1** implementation of both
`ProviderAuthorizationBackend` and `CredentialBackend`. OneAuth authorization
and OneSystem credential storage remain replaceable remote candidates, but are
not V1 runtime dependencies. There is no provisional remote branch:
unavailable evidence means local V1.

Authorization is local because none of OA-01..OA-05 provides the complete,
immutable OneAuth source/API, observed behavior, deployment owner, and operations
proof required by the gate. A social-login token authenticates product login; it
is not repository consent and cannot be stored or spent as a Git credential.

Credentials are local because OS-02 and OS-03 do not prove atomic
replace/version/revoke or `lease_for_operation`/`consume_lease`, while OS-04
proves a forbidden generic decrypt endpoint returning plaintext. OS-01 proves
only that a SOPS/Age storage primitive works. It does not prove the required
credential-use boundary.

The evidence ledger is
`docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md`.

## Frozen replacement boundary

- `ProviderAuthorizationBackend`: `begin_authorization/1`,
  `consume_callback/1`, `reauthenticate/1`, `cancel_authorization/1`.
- `CredentialBackend`: `store/1`, `replace/1`, `status/1`,
  `lease_for_operation/1`, `consume_lease/1`, `revoke/1`.
- `Ezagent.ActionSet.GitTaskAccess` remains the only Git-operation authorization
  entry. Backend possession or remote status never becomes a second authority.
- Provider adapters retain private Req ownership, credential-wrapper unwrap,
  provider HTTP, response normalization, and lease-consumption orchestration.
  A backend replacement cannot move Req ownership into the backend.
- No generic plaintext retrieval (`decrypt`, `get_plaintext`, `fetch_secret`,
  export, or caller-selected retrieval) is permitted.

### D0.1 correlation reconciliation clarification (2026-07-18)

The callback names and arities above remain frozen. Their mutating commands use
`correlation_id` as a durable idempotency key bound to the operation class and
all authority-bearing input. After a committed effect whose response is lost,
an exact retry returns the same logical result without repeating the effect.
Reusing the key with different input fails closed. A callback replay with a new
correlation id returns `callback_already_consumed`.

This clarification resolves a contradiction between the original prose and
the already-required remote-shaped after-commit reconciliation tests. It does
not add a callback, weaken single consumption, permit plaintext retrieval, or
change the authorization/credential replacement boundary.

Durable implementations enforce uniqueness of
`{backend_id, operation_class, correlation_id}`, compare a canonical bound-input
digest on retry, and enforce one committed consume command per authorization
ref. Authorization and credential implementations are selected only as a
conformance-tested handoff-compatible pair; the opaque handoff does not promise
an arbitrary cross-product of independently selected modules.
The handoff is a stable pair-private opaque reference. Any retained payload is
authenticated ciphertext, is destroyed after credential store and pointer
finalization, and leaves only a non-secret idempotency tombstone.

## Remote authorization approval rule

A future OneAuth backend may be selected only when every OA item passes at one
immutable version: canonical subject/entity/workspace mapping; recent-auth/AAL
binding; governed provider catalog/client metadata; separation of product login
from connected-account repository consent; complete callback lifecycle and
closed errors; and operational proof for availability, service authentication,
rotation, audit retention, incident response, and local development. Any new
runtime dependency requires explicit lead authorization.

## Remote credential approval rule

A future OneSystem backend may be selected only when one immutable contract
passes all of: opaque scoped refs; atomic replace/version CAS/revoke; short-lived
operation-, host-, owner-, workspace-, and version-bound lease issue; one-shot
`consume_lease`; provider-adapter-only unwrap; no generic decrypt surface; closed
failure behavior; and complete operational ownership. Wrapping the current
generic decrypt endpoint is not an acceptable adapter.

## Compatibility and authority

- Plan A is unchanged: its provider adapter keeps Req ownership.
- Plan B is unchanged: all Git provider calls remain behind `GitTaskAccess` and
  its `OperationContext`.
- Plan C is unchanged: task workspace/worktree provisioning receives no provider
  credential and gains no backend dependency.
- Kanban is unchanged: it stores task/PR data only and receives no token,
  credential ref, lease, authorization code, or backend status.
- OneAuth and OneSystem cannot become CapBAC, task-policy, connection-state, or
  Git-operation authority sources.

## D1 prerequisites and D2 blockers

D1 may plan the local authorization backend against the frozen interface. It
must add durable connection state, PKCE, single-consume callbacks, governed-host
binding, reauthentication, closed errors, audit policy, and tests without adding
provider HTTP outside adapters. Remote authorization remains blocked on all
OA-01..OA-05 evidence and lead approval.

D2 may plan the local encrypted credential backend against the frozen interface.
It must define encryption-at-rest/key rotation, opaque refs, atomic versioned
replace/revoke, operation-bound lease issue/consume, crash/race behavior,
secret-safe audit, and local-development operation. Remote credentials remain
blocked on OS-02/OS-03, remediation or removal of OS-04, complete operations
evidence, and lead approval.

## Non-authorization

This decision does not implement or authorize a production backend, OAuth flow,
token persistence, provider HTTP, UI, migration, deployment, merge, OneAuth or
OneSystem change, Plan C change, or Kanban change.
