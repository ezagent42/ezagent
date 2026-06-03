# Lifecycle persistence-access discipline (2026-06-03)

**Principle (Allen 2026-06-03):** persistence and the create-vs-activate
decision are **framework / Lifecycle concerns**. Behavior / plugin /
domain code goes through the Lifecycle macro and the framework's *defined
functions* — never the low-level persistence primitives directly. "基于
lifecycle，不要基于特定的函数；用 lifecycle 的宏或者定义好的函数。"

This note records the scan result, the enforcing lint, and how we keep it
from drifting.

## Why this came up

While building #533 PR-5a, an early attempt surfaced the "did this call
just create the row" freshness signal by adding a second snapshot-save
function (`save_initial/4`) that returned `:created | :existed` from the
atomic-insert result. That introduced a **6th** save-ish surface and a
parallel way to derive create-vs-activate — exactly the drift risk Allen
flagged. It was reverted. The signal now comes from one Lifecycle-owned
function, `Ezagent.Lifecycle.fresh_create?/1`, read in `Kind.Server.init/1`
before the initial persist sets the marker.

## Scan result (2026-06-03) — already clean

Scanning all `apps/*/lib` for the three access axes:

| Axis | Primitive | Production callers (all framework) |
|---|---|---|
| Snapshot WRITE | `KindSnapshot.upsert/6` | `kind/snapshot.ex`, `snapshot_store.ex` only |
| Sync write | `Kind.Snapshot.save_now/4` | `kind/server.ex`, `snapshot/writer.ex`, `kind/snapshot.ex` (commit) only |
| Create/activate READ | `KindSnapshot.ever_created?/1` | `lifecycle.ex` (+ `kind_snapshot.ex` definition) only |

No Behavior / plugin / domain module writes snapshots, calls `save_now`,
or reads the marker directly. The single production write path is
`commit/4` (policy gate) → `save_now/4` (primitive), plus the async
`Writer` and `terminate`. The single create/activate signal is
`Lifecycle.fresh_create?/1`.

## The enforcing lint

`apps/ezagent_core/test/invariants/lifecycle_persistence_access_test.exs`
— a source-scan invariant (same mechanism as
`agent_create_single_path_test.exs`). It fails if any non-allowlisted
production file matches one of the three forbidden-call regexes. Verified
to fire on an injected violation (not a vacuous green). Runs in CI with
the rest of the suite.

To extend the framework legitimately, add the file to the rule's
`@allowlist` with a one-line justification — the allowlist *is* the
enumerated set of framework persistence sites.

## Known follow-ups (separate, lower priority)

These are NOT current violations of the lint (no production callers), but
they are residual *surface* that could become drift seeds:

1. **`Kind.Snapshot.maybe_save/4`** — only test callers; production-dead
   (codex already flagged it "lies" / returns `:ok` on failure). Delete
   it and migrate its 3 tests to `commit/4`.
2. **`SnapshotStore.write/3`** — only test callers; tests use it to *seed*
   snapshot rows. It is a second write encoder over `kind_snapshots`
   (version-incrementing) parallel to `save_now`. Migrate test seeding to
   the production write path and keep `SnapshotStore` as read/ops only
   (`latest/1`, `delete/1`, `count/0`), or have one delegate to the other
   so there is a single encoder. Tracked as its own cleanup task.
3. **Read path** — admin LVs / dumps call `KindSnapshot.get/list_all/
   decode_state` directly for *display*. That's observability, not state
   rebuild, so it's out of this invariant's scope; state *rebuild* already
   goes through `StateRebuilder` / `SnapshotStore.latest`.

## How we avoid this in future

- The lint is the durable guard — a new direct call to any of the three
  primitives fails CI with guidance naming the right Lifecycle/framework
  function.
- This note + the lint's `@moduledoc` are the written principle.
- When a new persistence need appears, extend the framework function (and
  its allowlist entry), do not add a parallel save/marker path.
