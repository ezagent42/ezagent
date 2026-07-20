# Git Provider V1 Plan D1 system-closure amendment

**Status:** approved for implementation; assurance Decision B approved 2026-07-20

**Amends:** the 2026-07-18 D1 connection-substrate design and the 2026-07-19/20 fence and reconciliation amendments

**Does not change:** the D0/D0.1 callback surface, provider neutrality, decentralized capability ownership, or the GitTaskAccess policy

## 1. Why this amendment exists

The D1 implementation started from an already-created, already-bound
`ProviderConnection`. That skipped three domain protocols:

1. aggregate birth before the provider account is known;
2. the single point where callback output becomes immutable connection identity;
3. durable ownership of every external result before a worker may lose its fence.

Fixtures hid the first gap with `pending:*` account ids and `pending` backend
references. Direct `Store.execute/3` tests hid missing public actions and the
production assurance bridge. Operation-status assertions hid the wrong public
receipt. The result was locally green code without a complete system contract.

This amendment closes those protocols. It does not introduce a central grant
table. Capability issuers still sign artifacts, grantees/processes carry them,
and the target User Kind remains the central dispatch verifier.

## 2. Aggregate birth and pending identity

`begin_authorization` is the only initial creation command. Its arguments name a
caller-chosen UUID `connection_id` plus owner-scoped provider, host, acquisition,
requested execution-identity class, permission, redirect, correlation, and an
owner-bound callback continuation artifact.

The first transaction locks the `connection_id` key and either:

- inserts a `pending_authorization` connection and a `beginning` attempt
  reservation; or
- reconciles an exact retry of the same reservation.

A conflicting correlation/digest fails closed. Existing active, degraded,
expired, revoking, revoked, disconnecting, or disconnected rows cannot enter the
initial-begin path.

Before first binding these fields are `NULL`, never sentinel strings:

- `external_account_id`;
- `display_login`;
- final canonical `execution_identity`;
- `authorization_backend_ref`;
- `credential_backend_ref`;
- `permission_digest` and provider expiry.

The pending row stores only owner/workspace, provider/normalized host,
acquisition method, and the requested execution-identity class. Pending rows are
not selectable by Git or adapter consumers.

The backend call occurs after the reservation transaction. A second transaction
locks connection then attempt, persists the returned authorization coordinates,
and advances `beginning -> pending`. Exact begin retries recover the same
reservation and backend correlation.

## 3. Initial callback is the identity convergence point

The normalized callback result is first journaled durably on the operation:

- external account id;
- display login;
- canonical execution identity;
- granted permission digest and expiry;
- authorization ref/version;
- credential ref/version;
- provider-result reconciliation coordinate.

No credential material is stored in those fields.

The connection CAS locks connection, attempt, and operation in that order. For
an initial bind it atomically commits all normalized identity, backend binding,
credential pointer, versions, `status = active`, and the operation transition to
`connection_committed`. A retry returns the same public receipt.

The active uniqueness tuple remains:

```text
(workspace_uri, owner_uri, provider_id, governed_host,
 external_account_id, execution_identity)
```

It applies only when `external_account_id IS NOT NULL` and the row is not
terminal. Concurrent pending authorizations may exist because the provider
account is not yet known. At CAS only one identical real binding wins. A loser
retains no active pointer. In the same transaction its connection becomes the
non-selectable terminal state `failed` with `last_error_code = account_conflict`,
its attempt becomes `cancelled`, and its operation becomes `cleanup_pending`.
Both its provider result and credential result are durably compensated. Exact
callback retry observes those terminal coordinates and returns the stable closed
error `account_conflict` without repeating CAS or cleanup creation. Cleanup may
finish after the aggregate is terminal; it never makes the connection selectable.

Reauthorization may update authorization/credential versions, permissions,
expiry, and display login, but must match the immutable external account and
canonical execution identity. Identity drift is an account conflict and cannot
replace the old pointer.

## 4. Command matrix and linearization

Every command locks/reloads its aggregate before an external effect.

| Command | Allowed source |
|---|---|
| initial begin | missing connection, or exact retry of its open reservation |
| reauthorize | `active`, `degraded`, `expired` with exact version and assurance |
| initial callback | `pending_authorization`, matching initial attempt generation |
| reauthorization callback | `active`, `degraded`, `expired`, matching reauth generation |
| read | every existing state, exact owner/workspace |
| refresh | `refresh_required`, or an expired `refreshing` lease |
| revoke/disconnect | the approved D1 termination sources with assurance |

`reauthorize` receives permission, redirect, correlation, requested identity,
and an owner-bound callback artifact in addition to connection/version and
assurance. It reserves a new attempt under the connection lock. Terminal or
refresh transitions racing it can have only one linearization winner.

`read_connection` returns a safe allowlisted view. It never returns authorization
or credential refs, backend implementation ids, attempt/operation ids, claim or
lease tokens, artifacts, ciphertext, or internal operation states.

Public callback receipts always use the connection source of truth:

```elixir
%{connection_id: id, status: connection.status, version: connection.connection_version}
```

## 5. Callback capability subject and cold targets

Management command authority and callback continuation authority are distinct:

- the management action cap may be held by the owner or a delegated operator;
- the stored `consume_callback` artifact is always granted to the owner because
  ingress dispatches as the owner to the owner User Kind.

Begin validates callback artifact target, workspace, action, and
`grantee_uri == owner`; it must not bind the artifact to `ctx.caller`.

Artifact prevalidation supports a cold target without starting or regenerating
it. The framework helper verifies against the durable current target authority
generation/public key. A live Kind may use the existing path. A retired
generation, wrong target, wrong receiver, or wrong grantee fails. The helper
does not issue, store, dispatch, start a Kind, or authorize handler entry.
Router dispatch still performs the only action authorization and may cold-start
the owner normally.

## 6. Assurance boundary — Decision B

`Assurance` binds action, owner, workspace, grantee, connection id/version,
reauth reference/version, issued/expiry times, key id, and signature. It is not
reusable across `reauthorize`, `revoke`, and `disconnect`.

The provider-connection domain exposes a backend-neutral
`SessionAssuranceVerifier` port. The default remains fail-closed. A production
issuer/validator in the follow-up phase may mint an assurance only after
verifying trusted AAL2/AAL3 session evidence; a caller-supplied
`%{aal: :aal2}` is not evidence.

The repository currently has no trusted AAL2 authority. The approved choice for
this phase is:

- **B — deferred:** keep reauthorize/revoke/disconnect fail-closed in D1 and
  explicitly move production assurance and those public flows to a follow-up.

OneAuth remains a candidate for that follow-up, but it is a remote dependency
and requires separate lead approval. D1 may implement and test the closed port,
action binding, and fail-closed behavior; it must not claim production
reachability for the three assurance-gated actions.

All seven actions remain registered and have closed domain handlers. Production
reachability is intentionally split: begin, consume callback, refresh, and read
are reachable; reauthorize, revoke, and disconnect always fail closed at the
public User boundary. Production is wired directly to the unavailable validator
and runtime application configuration cannot open it. Test-only builds may
inject a verifier to exercise those three domain protocols.

Magic-link or ordinary login must not be relabeled as AAL2.

## 7. Recovery fairness and durable retry

Operations gain `recovery_attempts`, `next_recovery_at`, and a closed
`last_recovery_error_code`.

- every inspected row advances the in-pass cursor, success or failure;
- failure atomically increments attempts and schedules bounded exponential
  backoff with deterministic test clocks;
- recovery queries only due rows;
- a poison row cannot block later rows or later phases;
- an empty pass sleeps until the earliest due row (bounded by configuration),
  never self-schedules at zero milliseconds;
- the existing 50-row batch and 500-row pass yield remain;
- repeated permanent errors stay visible and retry forever with a capped
  backoff; D1 has no quarantine or skip state.

## 8. Refresh result ownership and compensation

`Driver.refresh/1` must return/reconcile a stable opaque provider-result
coordinate for its correlation. As soon as the provider effect exists, the
operation journals that coordinate before a worker may return.

The credential handoff also uses the stable operation correlation to produce a
reconcilable opaque credential ref. Only then is the connection lease checked
for pointer commit. A loser moves to `cleanup_pending` with two independent
durable obligations:

1. discard/revoke the exact provider refresh result through the driver;
2. revoke the exact credential backend result.

Both must confirm before cleanup finalizes. Recovery retries either obligation.
No branch may drop raw provider output merely because a post-effect lease check
failed.

## 9. Validation, secrecy, and relational invariants

Application constructors validate canonical owner/workspace URIs and their
relationship, closed provider/acquisition ids, normalized governed host,
canonical account and execution identity, closed status/error, and immutable
bound fields. Updates use named transition changesets; arbitrary changesets may
not alter immutable identity.

Forward migrations add relational guarantees from attempt/operation/event to a
real connection and enforce matching workspace where PostgreSQL can express it.
Where a composite foreign key is impractical, the locked application invariant
and its concurrency tests are mandatory.

`Inspect` redacts callback artifacts, claim/lease tokens, handoff/result/prior
credential refs, backend refs, refresh lease tokens, ciphertext/nonces, and
authorization refs. Runtime sentinel tests cover every durable struct, not only
the private backend record.

Migration DDL is fail-loud. New migrations do not use `IF NOT EXISTS`, and down
steps only reverse objects owned by that migration. Handoff finalization rejects
unknown lifecycle states; DB checks relate lifecycle, ciphertext, handoff ref,
and shredded timestamp.

## 10. Forward-only migration sequence

Previously committed migrations remain immutable. Add:

1. `20260720001000_reserve_pending_provider_connections.exs` — nullable pending
   identity/refs, requested identity, attempt purpose/reservation fields, and
   one-open-attempt constraint;
2. `20260720002000_close_provider_binding_cas.exs` — normalized callback result,
   final-binding checks, active uniqueness rebuild, relational constraints;
3. `20260720003000_add_provider_recovery_schedule.exs` — retry schedule and due
   index;
4. `20260720004000_add_refresh_compensation_obligations.exs` — provider result
   and two cleanup obligations;
5. no assurance persistence migration in this phase; production assurance is
   deferred by Decision B.

Each migration upgrades non-empty D1 data in an explicit
expand/backfill/validate sequence:

- attempt purpose is first nullable; existing open attempts on
  `pending_authorization` connections become `initial_bind`, while open attempts
  on every other state are cancelled and marked `legacy`; already consumed or
  terminal attempts are marked `legacy`;
- reservation/request fields remain nullable for `legacy` attempts and are
  required by a conditional check only for new `initial_bind`/`reauthorize`
  attempts;
- normalized callback-result fields remain nullable until an operation reaches
  the corresponding new committed state;
- existing operations receive `recovery_attempts = 0`; recoverable obligations
  receive `next_recovery_at = migration_time`, terminal rows receive `NULL`;
- existing refresh cleanup rows set provider cleanup to `not_required` because
  no durable provider-result coordinate exists, and credential cleanup to
  `pending`; other legacy rows use `not_required` as appropriate;
- constraints and indexes are added only after backfill and validation.

Upgrade tests seed active, pending, consuming, backend-committed,
cleanup-pending, refreshing, and termination rows on the pre-amendment schema,
then assert their exact post-migration mapping.

## 11. Acceptance

Tests must prove initial creation without sentinel values, all begin crash
windows, callback identity CAS, duplicate real-account race, reauth identity
drift, terminal/begin race, all seven registered handlers, the explicit four
reachable/three production-fail-closed split, cold owner callback, delegated
operator begin and delegated operator reauthorize with separate owner-bound,
continuation artifacts. Each attempt reservation/digest binds its artifact
identity to purpose, connection id, and connection generation, and rejects
cross-attempt/purpose/generation replay. The capability itself gains no new
purpose or connection-version axis. Tests also cover action-bound assurance,
poison-row fairness/backoff, every refresh lease-loss window, public receipt
semantics, canonical/immutable validation, relational mismatch rejection, and
secret-free Inspect/log/error/telemetry.

All Mix/BEAM verification runs serialized inside the approved 5G cgroup guard.
