# Clean-Slate Per-Grant Durable Revocation Design

**Status:** approved direction; pending adversarial review

**Decision date:** 2026-08-01

**Supersedes:** the protocol-version and maintenance-cutover portions of
`/Users/h2oslabs/P2_KIMI_HANDOFF.md`. The per-grant revocation kernel remains.

## 1. Context and decision

The application has not entered production. There is no customer database whose
existing capability artifacts must survive this change. Development databases will
be destroyed and initialized again before this branch is used.

Therefore the system will not ship a legacy/new protocol transition. There is one
capability grant mechanism:

- every issued grant artifact has a fresh `grant_id`;
- `grant_id` is covered by the authority signature;
- revocation inserts an immutable marker keyed by `grant_id`;
- authorization, durable writes, and delivery reject revoked artifacts;
- re-granting the same logical capability creates a different `grant_id`.

Terms such as `v1`, `v2`, `signing_version`, revocation epoch, cutover, remint, and
legacy compatibility are not part of the resulting runtime model.

## 2. Scope

### In scope

1. Remove the P2 protocol-version field and all version-aware branches.
2. Remove the P2 revocation epoch, activation transition, and durable epoch table.
3. Remove the P2 maintenance cutover/remint command, release entry point, semantic
   diff, manifests, destructive rebuild transaction, and their runbook/tests.
4. Make the signed `grant_id` contract unconditional for every issued grant artifact.
5. Preserve the independent revocation ledger and enforcement at every grant-artifact
   boundary.
6. Preserve exact-artifact revoke, fresh-ID re-grant, outbox enforcement, cold-restart
   enforcement, and the `EntityCaps` to `IdentityCaps` rename.
7. Replace activation/cutover acceptance with clean-database initialization acceptance.

### Out of scope

- Preserving any existing development data.
- Importing or reminting existing capability artifacts.
- Reconstructing historical direct grants from memberships, recipes, snapshots, or
  users.
- Automatically deleting a database from application startup.
- Removing unrelated historical migration mechanisms such as the existing identity
  Store cutover.
- Rewriting repository migration history that is unrelated to P2. Schema migrations
  needed to create the ledger and `grant_id` columns remain normal migrations.

## 3. Core model

### 3.1 Capability request versus grant artifact

The existing `%Ezagent.Capability{}` type represents both an unsigned capability
request and an issued artifact. These states have different requirements:

- An unsigned request or required-cap shape may temporarily have `grant_id: nil`.
- The single issue chokepoint overwrites any caller-supplied value with a fresh UUID.
- A signed grant artifact must have a syntactically valid, non-empty `grant_id`.
- Any held, persisted, restored, delivered, or authorized artifact missing a valid
  `grant_id` is malformed and is rejected.

`grant_id` remains excluded from `Capability.identity_key/1`. Logical revoke lookup
uses the capability identity, then records the exact stored artifact's `grant_id`.

### 3.2 Signature contract

The canonical signed payload always contains `grant_id`. There is no alternate payload
shape and no fallback verification path. Signature verification fails when `grant_id`
is missing, malformed, modified, or signed by a non-current authority.

Authority anchors that bypass the ordinary Grant issue function must also stamp a
fresh `grant_id` before signing.

### 3.3 Durable revocation ledger

`cap_revocations` remains core-owned and insert-only. Its primary key is `grant_id`;
audit columns retain workspace, holder, capability identity digest, target, key, and
revocation timestamp.

Markers are not deleted by snapshot cleanup, holder deletion, Store replacement, or
delivery cleanup. Marker garbage collection remains deferred.

## 4. Enforcement boundaries

The no-resurrection guarantee requires all of the following boundaries; clean database
initialization does not weaken them.

1. **Issue:** every new artifact receives a framework-generated `grant_id` before
   signing.
2. **Authorize:** signature/current-authority validation and one workspace-scoped
   revocation-ledger lookup run before artifact matching. Ledger read failure denies.
3. **Store:** all Store write paths share the in-transaction revoked-artifact guard.
   Missing/invalid `grant_id`, invalid signature, or ledger read failure rejects the
   write before persistence and reindexing.
4. **Effective load:** restored Store/snapshot/user artifacts are filtered through the
   same issued-artifact validity and revocation semantics before becoming held caps.
5. **Delivery:** enqueue and drain both reject an artifact whose `grant_id` is revoked;
   envelope semantic identity includes `grant_id`.
6. **Revoke:** one transaction locks the holder row, resolves the exact issued artifact,
   inserts the marker, removes it from Store, cancels matching pending delivery, and
   rebuilds the grantee index.

No epoch condition wraps these checks. They are always enabled.

## 5. Revoke and re-grant semantics

When a logical match exists in Store, revoke ignores caller-supplied grant metadata and
uses the signed stored artifact's `grant_id`.

When no Store match exists, revoke accepts only an exact signed artifact whose authority,
holder/grantee, target, and current generation verify. Random IDs, unsigned requests,
stale authority artifacts, and wrong-holder artifacts are rejected.

Re-granting the same logical capability mints a new `grant_id`; the old marker does not
block the new artifact. Reusing a revoked `grant_id` is rejected by Store and delivery
guards.

## 6. Clean database initialization

Database destruction is an explicit development/deployment prerequisite, not a runtime
side effect:

1. stop every application process using the development database;
2. drop and recreate the whole development database using the repository-supported
   reset workflow;
3. run all migrations from an empty database;
4. run seeds/bootstrap;
5. start the application;
6. create users, workspaces, sessions, and grants through normal application flows.

The reset discards users, workspaces, snapshots, direct grants, pending deliveries,
revocation markers, and all other development data. Nothing reads pre-reset rows and no
permission migration task runs before application start.

## 7. Removal map

The implementation removes or rewrites these P2 surfaces:

- `Ezagent.Cap.RevocationEpoch` and its Ecto schema/migration/tests;
- `Ezagent.Identity.CapRevocationCutover` and its tests;
- `EzagentCore.Release.cap_revocation_cutover/1`;
- protocol-version fields, encoders, digests, defaults, and conditionals;
- cutover-specific invariant allowlists, ratchet counts, docs, and acceptance tests;
- dry-run reports, semantic diffs, approved manifests, table/advisory locks, remint APIs,
  and pending-row cleanup that existed only for cutover.

It retains:

- `grant_id` on issued capability artifacts and delivery rows;
- `cap_revocations` and `Ezagent.Cap.RevocationLedger`;
- the shared Store revoked-artifact guard;
- authorize/effective-load/outbox enforcement;
- atomic revoke and exact-artifact validation;
- fresh-ID authority issuance and authority-anchor issuance;
- serializers and digests updated for the one mechanism;
- the final `IdentityCaps` naming.

## 8. Failure behavior

- Missing or malformed `grant_id` on an issued artifact: reject, never coerce.
- Invalid or stale signature: reject.
- Revocation-ledger read error: deny authorization and reject durable writes/delivery.
- Revoked `grant_id`: deny and reject persistence/delivery.
- Revoke cannot resolve a trustworthy exact artifact: return an error and write nothing.
- Transaction failure: roll back marker, Store mutation, outbox cancellation, and index
  mutation together.
- Database reset/bootstrap failure: application remains unstarted; there is no fallback
  to old data.

## 9. Acceptance contract

### Protocol and issuance

- No production source or test names a capability protocol version or revocation epoch.
- Every issued grant and authority anchor has a non-empty fresh `grant_id` covered by its
  signature.
- Caller-provided `grant_id` is overwritten at issuance.
- Tampering with or removing `grant_id` invalidates the artifact.

### Durable revoke

- Revoking one grant denies it immediately without revoking a logically different grant.
- Re-granting the same logical capability succeeds with a new `grant_id`.
- Store writes and outbox enqueue/drain reject a revoked `grant_id`.
- Live slice, snapshot, stale user JSON, and pending delivery cannot resurrect a revoked
  artifact after cold restart.
- Exact absent-from-Store revoke succeeds only for a valid signed artifact bound to the
  expected holder and target.

### Clean start

- The full schema migrates successfully from an empty database without an activation or
  cutover command.
- Seeds/bootstrap create only grants satisfying the single mechanism.
- The application starts directly with unconditional grant-ID enforcement.
- A source ratchet proves that epoch/cutover/version compatibility surfaces cannot be
  reintroduced silently.

### Gates

- touched application test suites;
- authorize-chokepoint and capability-issue ratchets;
- `mix format --check-formatted` for touched files;
- `mix ci.fast`;
- `mix precommit`.

## 10. Documentation authority

This document records the user's 2026-08-01 clean-slate decision and is authoritative
over the P2 handoff wherever the handoff requires inactive/active epochs, protocol
versions, backward-compatible decoding, maintenance remint, semantic migration diff, or
production cutover. The handoff remains authoritative for the per-grant ledger kernel,
atomic revoke semantics, enforcement boundaries, test discipline, branch, and delivery
constraints.
