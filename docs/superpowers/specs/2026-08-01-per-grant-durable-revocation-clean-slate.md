# Clean-Slate Per-Grant Durable Revocation Design

**Status:** implemented on the target branch after three adversarial review rounds;
delivery return recorded and final PR remains open for coordinator review

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

This removes capability **protocol** versioning only. Authority key generations and
the version encoded in `key_id` remain required for key rotation and current-authority
verification; they must not be removed or renamed as part of this work.

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
8. Remove the older Identity Store cutover compatibility plane as well: no
   `Identity.Cutover`, no cutover release/Mix entry point, no legacy-authoritative or
   dual-write mode, and no capability persistence in `users.caps_json`.
9. Make `IdentityCaps.Store` the sole durable source of held capabilities from the
   first process start on an empty database.

### Out of scope

- Preserving any existing development data.
- Importing or reminting existing capability artifacts.
- Reconstructing historical direct grants from memberships, recipes, snapshots, or
  users.
- Automatically deleting a database from application startup.
- Removing authority generation or key-version rotation semantics.
- Rewriting repository migration history that is unrelated to P2. Schema migrations
  needed to create the ledger and `grant_id` columns remain normal migrations.
- Removing Kind snapshots themselves. Snapshot `:identity` data may remain a runtime
  cache, but it is never an independent durable authority and must be reconciled and
  filtered against `IdentityCaps.Store` on load.

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

### 3.4 Canonical issued-artifact API

Request normalization and issued-artifact validation are separate APIs. The new
core-owned `Ezagent.Cap.GrantArtifact` contract is:

```elixir
@spec from_map(map()) :: {:ok, Capability.t()} | {:error, validation_error()}
@spec from_term(binary()) :: {:ok, Capability.t()} | {:error, validation_error()}
@spec validate(Capability.t()) :: {:ok, Capability.t()} | {:error, validation_error()}
@spec valid_grant_id?(term()) :: boolean()

@type validation_error ::
        :not_capability
        | :missing_grant_id
        | :invalid_grant_id
        | :missing_signature
        | :missing_key_id
        | :missing_grantee_uri
        | :invalid_term
        | {:invalid_field, atom()}
        | {:invalid_uri, atom()}
```

`Capability.Normalize` remains the request/declaration normalizer and may produce a
request with `grant_id: nil`. It no longer invents a protocol version or treats a missing
grant ID as a legacy artifact. Every artifact carrier routes decoded data through
`GrantArtifact.from_map/1` or `GrantArtifact.validate/1` before the artifact can be held,
persisted, restored, delivered, or authorized. Carriers include Store JSON, live/snapshot
identity sets, delivery envelopes, recipe-binding artifacts, and any serializer that
rehydrates signed grants.

The finite carrier inventory is:

1. `identity_caps.caps_json` Store sets;
2. live and snapshot `:identity` cap sets;
3. delivery-outbox payloads and `DeliveryOutbox.Envelope` values;
4. provider callback ingress and persisted callback-attempt artifacts;
5. `RecipeCapBinding.artifacts`;
6. `kind_cap_authorities.anchor`, a single artifact stored as an Erlang term;
7. capability Jason/EventLog decode paths;
8. provisioning-receipt or provider-callback serializer fields only when they contain a
   rehydratable artifact (a digest-only field is not an artifact carrier);
9. exact artifacts accepted by absent-from-Store revoke.

`GrantArtifact` also exposes an all-or-nothing set validator:

```elixir
@spec validate_set(Enumerable.t(), term()) ::
        {:ok, MapSet.t(Capability.t())}
        | {:error, {:invalid_grant_artifact, term(), non_neg_integer(), validation_error()}}
```

An invalid element rejects the entire carrier set; readers never drop only the malformed
element and continue. Empty `grant_id`, signature, or `key_id` values are treated as
missing. Wrong field types return `{:invalid_field, field}` and malformed URI fields
return `{:invalid_uri, field}`; these two tuple forms are included in
`validation_error()`. Every listed carrier has a focused test proving malformed input
fails the whole read closed.

The canonical `grant_id` representation is the lowercase hyphenated UUID text returned
by `Ecto.UUID.generate/0`. Validation requires `Ecto.UUID.cast/1` to succeed and the
canonical cast result to equal the input exactly.

`GrantArtifact.from_term/1` uses `:erlang.binary_to_term(binary, [:safe])`, accepts only
a `%Capability{}`, and then calls `validate/1`; every decode exception or unexpected term
returns `{:error, :invalid_term}`. `Ezagent.Cap.Authority` returns an anchor only after
this safe decode, row/key/target/current-authority signature verification, and a
revocation-ledger check. Corrupt, missing-ID, noncanonical-ID, stale, or revoked anchors
fail closed and never enter admin or carried authorization caps.

## 4. Enforcement boundaries

The no-resurrection guarantee requires all of the following boundaries; clean database
initialization does not weaken them.

1. **Issue:** every new artifact receives a framework-generated `grant_id` before
   signing.
2. **Authorize:** signature/current-authority validation and one workspace-scoped
   revocation-ledger lookup run before artifact matching. Ledger read failure denies.
3. **Store:** all Store write paths share the in-transaction artifact-shape and
   revoked-artifact guard. Missing/invalid `grant_id`, missing signed-artifact fields,
   a revoked ID, or ledger read failure rejects the write before persistence and
   reindexing.
4. **Effective load:** restored Store/snapshot/recipe artifacts are filtered through the
   same issued-artifact validity and revocation semantics before becoming held caps.
5. **Delivery:** enqueue and drain both reject an artifact whose `grant_id` is revoked;
   envelope semantic identity includes `grant_id`.
6. **Revoke:** one transaction locks the holder row, resolves the exact issued artifact,
   inserts the marker, removes it from Store, cancels matching pending delivery, and
   rebuilds the grantee index.

No epoch condition wraps these checks. They are always enabled.

The new per-grant Store guard is intentionally not a second current-authority verifier.
It does not remove or weaken the Store's existing authority lock that atomically protects
the active-row/current-self-license lifecycle invariant. Cryptographic
signature/current-generation verification remains fail-closed at authorize, effective
load, delivery consumption, and exact-revoke trust boundaries. This preserves P2's
no-resurrection scope without introducing authority-row locking into every Store writer.
The Store can contain a structurally valid but cryptographically stale artifact, but such
an artifact cannot become effective authority. Existing self-license regenesis-race
coverage remains mandatory; only additional per-target authority locks for the new
per-grant guard are out of scope.

### 4.1 Store-first mutation and bootstrap protocol

`IdentityCaps.Store` being authoritative is a write-order invariant, not merely a read
preference. Every mutation of a held identity cap set follows this sequence:

1. issue/normalize the proposed artifacts;
2. synchronously enter the Store transaction, lock the holder row, apply artifact-shape
   and revocation guards, update Store, cancel/reindex as applicable, and commit;
3. only after Store commit, replace the live `:identity` cap set with the exact committed
   Store result and write the snapshot projection;
4. acknowledge the mutation only after the checked Store commit. Snapshot projection
   failure never reverses Store authority; it crashes or marks the actor not-ready so a
   cold reload rebuilds from Store.

The existing snapshot-first `commit_and_notify` Store mirror is deleted for identity
caps. No snapshot callback performs a best-effort Store write. Grant/revoke/replace entry
points call the Store-owned mutation API first; direct live-slice mutation is forbidden
by a source invariant.

Creation is also Store-first. A user row and its initial Store row are inserted in one
Repo transaction. Other cap-bearing entities complete their Store genesis/provisioning
transaction before the Kind becomes visible or ready. There is no interval in which an
existing visible entity legitimately lacks a Store row.

Cold load has exact states:

- active Store row: its validated cap set replaces, never unions with, snapshot data;
- tombstoned/revoked-unprovisioned Store row: effective held caps are empty;
- Store read error: fail closed and refuse readiness;
- missing Store row for an existing entity: invariant violation; fail closed and refuse
  readiness;
- missing row is permitted only inside the uncommitted new-entity genesis transaction,
  before the entity is visible or spawnable.

Carried delegation in `ctx.caps` remains a separate authorization input and is not a
held-cap Store row. This section governs durable held capabilities.

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

The resulting runtime has one durable authority path:

- `IdentityCaps.Store` is authoritative unconditionally; there is no persisted cutover
  flag and no mode switch.
- `users.caps_json` is removed from the runtime schema by a normal schema-cleanup
  migration and from all schemas, create/update functions, and fallbacks.
- the old Identity cutover schema/table, release/Mix commands, runbook, backfill/remint
  helpers, dual-write code, and legacy fallback reads are deleted;
- snapshot `:identity` data is a cache only and cannot override Store contents during
  cold load.

## 7. Removal map

The implementation removes or rewrites these P2 surfaces:

- `Ezagent.Cap.RevocationEpoch` and its Ecto schema/migration/tests;
- `Ezagent.Identity.CapRevocationCutover` and its tests;
- `EzagentCore.Release.cap_revocation_cutover/1`;
- `Ezagent.Identity.Cutover`, its Ecto schema/table, release/Mix entry points,
  runbook, migration-only remint/backfill helpers, and compatibility tests;
- the `users.caps_json` column and every legacy-authoritative, fallback, or dual-write
  capability path;
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

### 7.1 Storage constraints

Historical migrations already on `main` keep their version, module, and DDL semantics.
The narrow exception is an executable call to a runtime module renamed by P2d: such a
call is updated to the current `IdentityCaps` module so an empty-database replay works;
no old-name compatibility module is retained. The branch's unmerged P2 migrations are
edited before merge, and one ordered cleanup migration is added:

1. `20260801000000_create_cap_revocations.exs` creates the ledger with a PostgreSQL UUID
   primary key.
2. The unmerged `20260801000100_create_cap_revocation_epoch.exs` is deleted; no empty
   database ever creates that table.
3. `20260801000200_add_grant_id_to_cap_delivery_outbox.exs` adds a PostgreSQL UUID
   `NOT NULL` column and the workspace/grant/status index. It intentionally fails on a
   non-empty incompatible database; the supported path is a clean reset.
4. `20260801000300_remove_identity_cap_compatibility.exs` drops the historical
   `identity_cutover` table and removes `users.caps_json`. The older migrations that
   originally create them remain unchanged so the full migration chain stays replayable.

The clean-start gate queries PostgreSQL's catalog after migration and asserts the final
columns, UUID types, nullability, indexes, and absence of both compatibility surfaces.

Every relational column that directly identifies an issued grant uses PostgreSQL UUID
semantics, not unrestricted text:

- `cap_revocations.grant_id`: UUID primary key, `NOT NULL` by definition;
- `cap_delivery_outbox.grant_id`: UUID `NOT NULL`, required by the Ecto changeset, with
  the workspace/grant/status index preserved.

The ledger and outbox Ecto schemas use `Ecto.UUID`; public APIs still expose canonical
UUID strings. JSON/term carriers cannot have database column constraints, so they must
pass `GrantArtifact` validation at decode and write boundaries.

## 8. Failure behavior

- Missing or malformed `grant_id` on an issued artifact: reject, never coerce.
- Invalid or stale signature at an effective-authority trust boundary: deny/reject.
  Store persistence alone is not a claim that an artifact is cryptographically current.
- Revocation-ledger read error: deny authorization and reject durable writes/delivery.
- Revoked `grant_id`: deny and reject persistence/delivery.
- Revoke cannot resolve a trustworthy exact artifact: return an error and write nothing.
- Transaction failure: roll back marker, Store mutation, outbox cancellation, and index
  mutation together.
- Database reset/bootstrap failure: application remains unstarted; there is no fallback
  to old data.

## 9. Acceptance contract

### Protocol and issuance

- No runtime capability source or ordinary test names a capability protocol version or
  revocation epoch.
- Every issued grant and authority anchor has a non-empty fresh `grant_id` covered by its
  signature.
- Caller-provided `grant_id` is overwritten at issuance.
- Tampering with or removing `grant_id` invalidates the artifact.
- Corrupt-term, missing-ID, noncanonical-ID, stale-signature, and revoked
  `kind_cap_authorities.anchor` fixtures all fail closed before entering authorization.

### Durable revoke

- Revoking one grant denies it immediately without revoking a logically different grant.
- Re-granting the same logical capability succeeds with a new `grant_id`.
- Store writes and outbox enqueue/drain reject a revoked `grant_id`.
- Live slice, snapshot, recipe binding, provider callback, and pending delivery cannot
  resurrect a revoked artifact after cold restart.
- Exact absent-from-Store revoke succeeds only for a valid signed artifact bound to the
  expected holder and target.

### Clean start

- The full schema migrates successfully from an empty database without an activation or
  cutover command.
- The resulting schema contains neither an identity/revocation cutover table nor
  `users.caps_json`; Store is authoritative immediately.
- Seeds/bootstrap create only grants satisfying the single mechanism.
- The application starts directly with unconditional grant-ID enforcement.
- A source ratchet proves that epoch/cutover/version compatibility surfaces cannot be
  reintroduced silently. The ratchet is scoped to capability protocol compatibility
  and must continue to allow authority key-generation/version code.

The executable gate is the Mix task
`apps/ezagent_core/lib/mix/tasks/ezagent.cap_revocation.verify_clean_start.ex`, invoked
through exactly one alias entry:

```elixir
"ci.clean_per_grant": ["ezagent.cap_revocation.verify_clean_start"]
```

`mix precommit` includes `ci.clean_per_grant` exactly once. CI and final-delivery
verification run `MIX_TEST_PARTITION=<unique> mix precommit`; there is no optional
equivalent gate.

`config/test.exs` accepts `EZAGENT_TEST_DATABASE` as an exact database-name override;
when absent it retains the ordinary partition database formula. The outer verification
task never starts `:ezagent_core` or any umbrella application. It creates the disposable
database through a direct admin connection, then launches every migration/seed/scenario
step as an OS child process with the same explicit environment:

```text
MIX_ENV=test
MIX_TEST_PARTITION=<the gate's unique partition>
EZAGENT_TEST_DATABASE=<the generated prefixed database>
```

Each child refuses to run unless its resolved `EzagentCore.Repo.config()[:database]`
equals `EZAGENT_TEST_DATABASE`. Migration, seed/bootstrap, first application scenario,
and cold-restart verification are separate child processes, so the second application
start is a real cold start. Before any child launch, the task asserts that the generated
database differs from the ordinary configured test database. No child command is
permitted without the override.

The task must:

1. derive a unique database name matching
   `~r/\Aezagent_pg_compat_test_clean_[a-z0-9_]+\z/` from a monotonic integer and random
   suffix; the public Mix-task interface does not accept a caller-provided database name
   to drop;
2. parse and revalidate the resolved name immediately before every create/drop, connect
   only to the same configured PostgreSQL server, and use `try/after` cleanup that drops
   only that exact name on every exit path;
3. create the database through the outer task's direct admin connection, then spawn
   isolated children for migration, seeds/bootstrap, first boot, and cold boot, all with
   the exact override above;
4. spawn the first normal-application child and assert authority-anchor and bootstrap
   grants pass `GrantArtifact` and current-authority validation;
5. issue, authorize, revoke, deny, re-grant with a fresh ID, and authorize the new grant;
6. exit the first child and launch a second normal-application child against the same
   generated database, then prove the old grant remains denied and the new grant remains
   authorized;
7. inspect the Store, authority anchors, ledger, and outbox schema; assert canonical
   signed grant IDs, UUID/NOT NULL constraints, Store-only authority, and absence of any
   P2 or Identity activation/cutover/remint step;
8. drop the disposable database on success or failure.

The mandatory `Ezagent.IdentityCapsTest` suite complements the process-level gate with
fault injection: Store-before-projection ordering, snapshot failure after Store commit,
cold-load replacement from Store, and missing/corrupt Store readiness denial. Carrier
owner suites cover outbox, recipe, provider, snapshot, and event-log boundaries. These
tests run in `ci.fast`/`precommit`; the clean-start task owns the empty-schema and real
cross-process persistence proof.

A unit test against an already migrated test database is not sufficient evidence.

### Source ratchet

`apps/ezagent_core/test/invariants/clean_slate_grant_protocol_test.exs` scans runtime
library source, configuration, and the umbrella Mix project. It rejects:

- `signing_version`;
- `RevocationEpoch`, `CapRevocationEpoch`, and `cap_revocation_epoch`;
- `CapRevocationCutover`, `cap_revocation_cutover`, and the removed cap-revocation
  cutover Mix/release entry points;
- runtime references to `Identity.Cutover`, `IdentityCutover`, `identity_cutover`,
  `PreEpochRemint`, or their Mix/release entry points;
- reads or writes of `users.caps_json` while allowing `identity_caps.caps_json`.

Narrow exceptions are the ratchet source itself, immutable historical migration
files that originally created retired columns/tables, and cleanup migration
`20260801000300_remove_identity_cap_compatibility.exs`. Authority `key_id` versions,
authority generations, and rotation code remain permitted. Every exception is an exact
file path. The clean-start verification task is also an exact-path exception because it
must name the retired schema objects to assert their absence; it cannot provide runtime
compatibility behavior.

### Gates

- touched application test suites;
- authorize-chokepoint and capability-issue ratchets;
- `mix format --check-formatted` for touched files;
- `mix ci.fast`;
- `mix precommit`.

### Implementation evidence map

- Artifact identity, canonical UUIDs, issuance overwrite, and signature binding:
  `grant_artifact_test.exs`, `capability_protocol_test.exs`, and
  `authority_verify_against_current_test.exs`.
- Authority-anchor fail-closed behavior: `authority_anchor_validation_test.exs`.
- Atomic exact revoke, fresh-ID re-grant, Store write rejection, and absent-Store exact
  validation: `identity_caps/store_test.exs`.
- Store-first projection semantics and cold repair/readiness denial:
  `identity_caps_test.exs`.
- Durable delivery and restart enforcement: `delivery_outbox_hardening_test.exs` plus
  recipe/provider carrier suites.
- Compatibility removal and final PostgreSQL schema:
  `clean_slate_grant_protocol_test.exs` and
  `20260801000300_remove_identity_cap_compatibility.exs`.
- Empty-database/restart acceptance:
  `mix ezagent.cap_revocation.verify_clean_start`, wired exactly once through
  `ci.clean_per_grant` in `precommit`.

## 10. Branch and PR delivery

- The integration target remains `feat/p2-per-cap-revocation`.
- Future implementation sub-phases may use child branches and PRs targeting the
  integration target. After that sub-phase's required tests pass, the implementing
  agent is authorized to merge the sub-phase PR into the integration target.
- Commits already made directly on the integration target do not need retroactive
  sub-phase PRs.
- Completion requires pushing the integration target and opening one final PR from
  `feat/p2-per-cap-revocation` to `main`.
- The final PR must remain open for coordinator review. The implementing agent must not
  merge the final PR or otherwise merge the integration target into `main`.

## 11. Documentation authority

This document records the user's 2026-08-01 clean-slate decision and is authoritative
over the P2 handoff wherever the handoff requires inactive/active epochs, protocol
versions, backward-compatible decoding, maintenance remint, semantic migration diff, or
production cutover. The handoff remains authoritative for the per-grant ledger kernel,
atomic revoke semantics, enforcement boundaries, test discipline, and branch identity.
Section 10 supersedes the handoff's final-PR prohibition and defines the current delivery
contract.
