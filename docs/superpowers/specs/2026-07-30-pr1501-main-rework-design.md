# PR #1501 Current-Main Convergence Design

**Date:** 2026-07-30
**Frozen base:** `main@81a90855c353aae7ed832a5b988bb5dff711ccc5`
**Status:** Approved

## Goal

Make capability-grant idempotence observe both capabilities already held by an
entity and durable `:absorb_cap` deliveries that are still pending, while
preserving the identity-plane authority and fail-closed contracts introduced by
#1621.

## Non-goals

- The delivery outbox does not become a permanent capability authority.
- Existing applied or dead delivery rows do not reserve a capability identity.
- This change does not replace the current `EntityCaps.Store` cutover protocol.
- This change does not restore direct actor-internal access or legacy store
  reads.

## Authority Model

Held capabilities remain authoritative. Their durable read must preserve the
current `Ezagent.EntityCaps.load_persisted/1` semantics:

- an active cutover epoch reads the unified `EntityCaps.Store`;
- an inactive epoch reads the legacy projection;
- an unreadable epoch denies;
- a present non-active unified-store row is authoritative-empty;
- a unified-store read error denies and never falls back.

Pending absorbs are a temporary supplement used only to close the interval
between durable acceptance and successful application to the identity slice.
Once a delivery becomes `applied` or `dead`, it leaves the effective pending
view.

## Effective Read Contract

`Ezagent.EntityCaps` exposes tagged-result effective readers for callers that
must distinguish an empty set from an unknown set:

```elixir
effective_caps(uri) ::
  {:ok, [Ezagent.Capability.t()]} | {:error, :effective_caps_read_failed}

effective_caps_persisted(uri) ::
  {:ok, [Ezagent.Capability.t()]} | {:error, :effective_caps_read_failed}
```

The operation order is:

1. Read and validate pending absorbs through the core-owned outbox seam.
2. Read held capabilities through the existing live or durable authority path.
3. Merge and deduplicate the union with `Capability.identity_key/1`.

Pending-first ordering prevents a pending-to-applied transition from
disappearing between two reads. If application occurs between the reads, the
same capability appears in both sets and is deduplicated. Held-first ordering
could miss the capability entirely.

The persisted effective reader must wrap the existing authoritative persisted
reader rather than directly selecting `UserStore`, snapshots, or
`EntityCaps.Store`. This keeps #1621's epoch decisions in one place.

Any malformed slice, malformed pending envelope, database failure, transient
live read failure, or unexpected result makes the whole effective read fail
closed. Grant callers must skip the grant when they receive an error; they must
not reinterpret it as an empty set.

## Core Outbox Read Seam

`Ezagent.Cap.DeliveryOutbox` owns a read-only function that:

- scopes by workspace and target;
- selects only `status == :pending` and `op == :absorb_cap`;
- decodes every row through the versioned `Envelope.decode/1` contract;
- returns `{:ok, caps}` only if every selected row is valid;
- returns a tagged error for a missing workspace binding, database failure, or
  malformed pending row.

Domain code does not query the outbox schema or decode its payloads.

## Atomic Pending Identity

The outbox schema gains a nullable `semantic_identity` string. Canonical
identity-absorb producers populate it from `Capability.identity_key/1`.

PostgreSQL enforces a partial unique index over:

```text
(workspace_uri, target_uri, op, semantic_identity)
WHERE status = 'pending'
  AND op = 'absorb_cap'
  AND semantic_identity IS NOT NULL
```

Insertion uses an explicit conflict target matching that partial index and
`on_conflict: :nothing`. An ignored insert is followed by a scoped lookup of
the winning pending row. The stored envelope is decoded and its capability
identity compared with the requested identity before reuse.

Existing producer `idempotency_key` behavior remains distinct:

- a producer-key collision requires byte-identical payload reuse;
- a semantic collision permits different signed artifacts only when their
  capability identity keys are equal;
- unrelated unique-constraint failures remain durable-acceptance errors.

Because the index covers pending rows only, an applied or dead delivery releases
the identity for a later legitimate revoke/regrant lifecycle. No historical
backfill is needed for already non-pending rows.

## Grant Callers

Existing grant chokepoints that currently check held caps before issuing or
absorbing a capability will use the appropriate effective reader:

- live-safe callers use `effective_caps/1`;
- callers executing inside another Kind callback use
  `effective_caps_persisted/1` to avoid cross-Kind blocking.

Each caller handles the tagged result explicitly:

- `{:ok, caps}` continues the existing identity check and grant behavior;
- `{:error, _}` skips the grant and emits the existing error/telemetry signal
  appropriate to that boundary.

No new grant entry point is introduced.

## Verification

Tests are written before production changes and cover:

- held-only, held-plus-pending, and cold-empty effective reads;
- active, inactive, and unreadable identity-cutover outcomes;
- malformed identity data, malformed pending envelopes, and database failures
  failing closed;
- two concurrent semantically equivalent absorbs producing at most one pending
  delivery;
- producer-key conflicts remaining strict;
- applied and dead rows not blocking a new pending lifecycle;
- all affected grant callers using the effective view and skipping on read
  errors;
- core/domain dependency and CapBAC invariant gates;
- the repository `mix precommit` alias.

## Migration and Rollback

The migration is additive: one nullable column and one partial unique index.
Rollback drops the index and column. Application rollback remains safe because
older code ignores the nullable column; database rollback must happen only
after old application code is active.

