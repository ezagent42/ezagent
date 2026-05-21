# Phase 4 Completion — Spec 04: Per-Kind Snapshot Strategy (`Ezagent.Kind.Snapshot` real impl)

**Status:** DRAFT for Allen review. NO CODE YET.
**Closes:** Decision #27's promise of 4 working snapshot strategies, plus the Phase 1 stub left in `Ezagent.Kind.Snapshot` that ships `:save_skipped_phase1` telemetry instead of an actual write.
**Companion to:** Decision #59 (`:on_change` = `new_slice != old_slice`), Decision #62 (`type_name` stable id), Decision #91 (MessageStore is single-truth for chat history).
**Distinct from:** Phase 4 D7 / Decision #109 — see §0 immediately below.
**Reading time:** ~8 minutes.

---

## 0. What this spec is NOT (read this first)

There are **two different "persistence" stories** in Ezagent after Phase 4 and they keep getting conflated:

| Concern                                         | Mechanism                                                                 | Spec     |
| ----------------------------------------------- | ------------------------------------------------------------------------- | -------- |
| **Workspace declarative config** (members, session_templates, routing_rules) | `Ezagent.Workspace.Store` → SQLite `workspaces` table → `Ezagent.Workspace.Loader` rehydrates on boot | #109     |
| **Per-Kind runtime state slices** (Identity caps, Chat last_seen, etc.) | `Ezagent.Kind.Snapshot` → SQLite `kind_snapshots` table → `Ezagent.Kind.Server.init/1` rehydrates | **THIS** |

The `Workspace` Kind itself stays `persistence :ephemeral` (`apps/ezagent_core/lib/esr/entity/workspace.ex:61`) — because its "content" *is* its config, which the Loader rebuilds from `workspaces` table on boot. **Per-Kind snapshot would be redundant and racy with the Store.** This spec only addresses Kinds whose state changes *during runtime in ways the config layer doesn't capture* (e.g., a User's granted caps grow over time; an Agent's last-pong timestamp ticks every heartbeat).

If a future Kind ever needs both (config-from-Store **and** runtime-state-from-Snapshot), they layer cleanly: Loader picks the Kind based on config, `Server.init/1` then asks Snapshot for any per-instance state. They never write to each other's tables.

---

## 1. Problem statement

Decision #27 advertises 4 snapshot strategies — `:ephemeral`, `{:snapshot, :on_change}`, `{:snapshot, :periodic, ms}`, `:on_terminate` — plus an implicit 5th, `:external` (state lives in a foreign system; don't snapshot). Today:

- `apps/ezagent_core/lib/esr/kind/snapshot.ex` is a **Phase-1 skeleton**: `load_or_init/3` always misses (the SELECT is a stubbed `:error`), `maybe_save/4` emits `[:ezagent, :persistence, :save_skipped_phase1]` telemetry instead of writing.
- `apps/ezagent_core/lib/esr/kind/server.ex:70,104,108,120,126` already calls into the skeleton at the right four sites (init + 4 dispatch paths). The wiring exists.
- `apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:36-43` already created the `kind_snapshots` table: `uri` PK, `kind_type`, `state` (`:map`), `version`, `updated_at`. **No new migration needed for the basic case** (one open question on `state` column type — see Q1).
- `Ezagent.Kind.Server.terminate/2` is a no-op with a `# Phase 3 wires snapshot-on-shutdown here` comment.
- `Ezagent.Kind.persistence_policy` typespec at `apps/ezagent_core/lib/esr/kind.ex:28-31` does **not** include `:on_terminate` or `:external`. The behaviour spec is narrower than Decision #27 advertises.

Consequence: **`Ezagent.Entity.User` declares `{:snapshot, :on_change}` (`apps/ezagent_core/lib/esr/entity/user.ex:73`) but its Identity caps are still lost on every restart.** Phase 3d's `:caps_granted` work is observably non-durable. Same problem will bite any Phase 5+ Kind that wants to remember anything.

This spec lands the real implementation, finishes the typespec, and writes the promotion plan for existing Kinds.

---

## 2. Design

### 2.A Schema — finalize the existing `kind_snapshots` table

The migration is already in place. Two open items:

| Column        | Current                  | Spec recommendation                                                                                                                          |
| ------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `uri`         | `:string`, PK            | Keep. One snapshot per Kind instance. URI is the natural key (matches `KindRegistry`).                                                       |
| `kind_type`   | `:string`, not null      | Keep. `Decision #62` — `kind_module.type_name()` (e.g. `"user"`), **not** the module name. Snapshot survives `Ezagent.Entity.User → Ezagent.User` rename. |
| `state`       | `:map` (Ecto `:map` → JSON-encoded in SQLite via `EzagentCore.Repo` adapter) | **CHANGE recommended** to `:binary` and store `:erlang.term_to_binary(state)`. Lossless for `MapSet`, `URI`, `DateTime`, atoms. See Q1 below — JSON requires custom codec per slice and silently flattens `MapSet → list`. |
| `version`     | `:integer`, default 0    | Keep. Used by `Ezagent.Behavior.<X>.init_slice/1` upgrade path (see §2.G).                                                                       |
| `updated_at`  | `:utc_datetime_usec`     | Keep. Add a `:inserted_at` column too (paired) — useful for "how long has this instance been persisted." Trivial migration delta.            |

**Unique index:** the table uses `uri` as PK already — `(uri)` uniqueness is satisfied. The original prompt mentions `(uri, slice_key)` unique index; **this spec does NOT split per-slice rows.** §2.B explains why per-Kind is the right granularity for v1.

**Required migration (small, additive):**

1. Add `state_binary :binary` column.
2. Add `inserted_at :utc_datetime_usec` column (nullable initially; backfill `= updated_at` on existing rows; then NOT NULL).
3. Drop nothing yet — leave `state :map` for one release as belt-and-suspenders; new writes go to `state_binary`, reads prefer `state_binary` then fall back to `state`.
4. Subsequent cleanup PR (Phase 5) drops `state :map`.

This is one short migration file (~30 LOC) following the same pattern as `phase4_workspaces.exs`.

---

### 2.B Granularity — per-Kind vs per-slice

The original prompt asked: per-slice rows (one DB row per `(uri, slice_key)`) or per-Kind (one DB row per `uri` holding the full slice map)?

**Recommendation: per-Kind for v1.**

- A Kind's slices are co-authoritative for its identity. Loading them atomically (one row) avoids "Identity slice restored, Chat slice not yet → behavior sees inconsistent self-state during boot."
- Per-slice multiplies row count by `length(behaviors())` for the same Kind. Identity + Chat = 2 rows for one User; a future 5-behavior Kind = 5 rows. SQLite handles this fine but the write amplification for `:on_change` is real.
- "Only write changed slices" optimisation can be added **at the write layer** without changing the schema: compute `changed_slices = Map.filter(new_state, fn {k, v} -> Map.get(old_state, k) != v end)`; if `changed_slices == %{}` skip write; otherwise write the full new state. The dirty check already lives in `maybe_save/4`; the comparison just moves to the slice-map level (it's already there at the Kind level).
- Per-slice rows become attractive once a slice exceeds ~50KB and write contention matters. Phase 5+ can split with a backfill migration; the public API (`Snapshot.load_or_init/3`, `Snapshot.maybe_save/4`) is stable across this internal change.

So: **single row, full slice map**, written under per-Kind atomicity.

---

### 2.C Write hook — the `:on_change` path

**Where it lives today:** `Ezagent.Kind.Server.handle_call/handle_cast` already calls `Ezagent.Kind.Snapshot.maybe_save(uri, kind, old_state, new_state)` immediately after a successful `Ezagent.Kind.Runtime.handle_dispatch/4` return (lines 104, 108, 120, 126). The skeleton no-ops; this spec makes it actually write.

**Decision: sync or async?** (Decision Q2 below.) Recommendation:

| Strategy                    | Path     | Rationale                                                                                                                              |
| --------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `{:snapshot, :on_change}`   | **Sync** | Small payload (one row), low frequency (only when slice changes), and the user-visible expectation is "after dispatch returns, state is durable." Sync write is ~1ms on local SQLite; this is the right latency cost. |
| `{:snapshot, :periodic, ms}` | Async via `Ezagent.Snapshot.Writer` | Periodic is by definition fire-and-forget; the ms cadence already implies "best-effort." Mirrors `Ezagent.Audit.Writer` shape (Decision #60). |
| `:on_terminate`             | Sync     | `terminate/2` is blocking by definition; the GenServer is going down regardless. Best effort with try/rescue to avoid `terminate` crash. |

This split avoids the async-loss class of bugs for the high-value case (`:on_change`) while keeping the cheap-frequency case (`:periodic`) off the hot path.

**Failure mode (sync `:on_change`):**

- Write fails → `Ezagent.Kind.Snapshot.maybe_save/4` returns `{:error, reason}` instead of `:ok`.
- `Ezagent.Kind.Server.handle_call` currently asserts `:ok = ...`. Change to: log + emit `[:ezagent, :persistence, :failed]` telemetry, **but still return the dispatch result to the caller**. The slice change in memory is real; the snapshot just didn't make it to disk. The next change will retry the write naturally. See Q3 below — alternative is to crash the Kind.
- Memory `feedback_let_it_crash_no_workarounds` argues for crash. Counter: the dispatch already succeeded, the caller already has the result; crashing the Kind on the *next* line is a workaround for a downstream concern. **Spec preference: log + telemetry, do not crash. Surface via the existing `[:ezagent, :persistence, :failed]` event that Audit.Writer already uses.**

---

### 2.D Read hook — the boot path

Already wired: `Ezagent.Kind.Server.init/1` calls `Ezagent.Kind.Snapshot.load_or_init(uri, kind_module, args)` at line 70. The skeleton always falls through to `init_fresh/2`. This spec makes `fetch_snapshot/1` actually SELECT.

**Real implementation of `fetch_snapshot/1`:**

1. `EzagentCore.Repo.get(KindSnapshot, uri_str)` — one row by PK.
2. If `nil`: return `:error` → caller calls `init_fresh/2`.
3. If row found: `term = :erlang.binary_to_term(row.state_binary, [:safe])` (the `:safe` flag rejects atoms not already loaded — important for security; an attacker who could write the snapshots table shouldn't be able to inject arbitrary atom creation).
4. **Version check:** compare `row.version` to `kind_module.snapshot_version()` (new optional callback, see §2.G). If equal, return `{:ok, term}`. If older, hand to per-Behavior upgrade path. If newer, **crash** — running an older code version against newer snapshots is corruption-risk.

**`init_fresh/2` interleave:** `init_fresh` always runs every Behavior's `init_slice/1` to build the fresh map. If snapshot exists for *some* slices but a Kind has gained a new Behavior since the snapshot was written, the loaded `term` will lack the new slice. **Spec: after `:erlang.binary_to_term`, run `init_fresh` and *merge* — `Map.merge(fresh, loaded)`** so the loaded values win for existing slices and the new Behavior gets its fresh `init_slice` value. This is the simplest path that survives Behaviors being added to a Kind without a snapshot migration.

(For Behaviors being *removed* from a Kind, the loaded `term` carries an orphan slice key. `Ezagent.Kind.Server` never reads slices it doesn't have a Behavior for, so the orphan is harmless until the next write — at which point it's silently dropped because `init_fresh` only emits keys for current Behaviors. Net effect: removed-Behavior slice silently garbage-collected at next write. Acceptable for v1.)

**Boot-time restore is silent.** No log per Kind; that would be spammy on cluster start. Telemetry `[:ezagent, :persistence, :restored]` event emits once per Kind with `%{slices: map_size(state), bytes: byte_size(binary)}` for observability.

---

### 2.E Strategies — all four (five) finalized

| Strategy                          | Boot read       | Write trigger                          | Sync/Async | Notes                                                                  |
| --------------------------------- | --------------- | -------------------------------------- | ---------- | ---------------------------------------------------------------------- |
| `:ephemeral`                      | No (skip SELECT) | No (skip INSERT)                       | n/a        | Default. Today's Workspace, Session, Agent (latter two by inertia).    |
| `{:snapshot, :on_change}`         | Yes             | After every dispatch where `new_slice != old_slice` | **Sync**   | User, Phase-5+ stateful Kinds.                                          |
| `{:snapshot, :periodic, ms}`      | Yes             | Every `ms` ms via per-Kind timer (`Process.send_after(self(), :snapshot_tick, ms)` in `Server`, handled in `handle_info`) | **Async** via `Ezagent.Snapshot.Writer` | Suitable for "expensive change rate, eventually-consistent OK" Kinds.   |
| `:on_terminate`                   | Yes             | `Server.terminate/2`                   | **Sync** (terminate blocks anyway) | Suitable for Kinds with high-frequency change but graceful shutdown semantics (e.g. a long-running Session that should remember member list on planned restart but not every join/leave). |
| `:external`                       | **No** (skip SELECT — slice state lives in a foreign system) | No (skip INSERT)                       | n/a        | Plugin author must implement own `init_slice/1` that reads from the foreign system (e.g. an Agent backed by a PTY where `cwd`/`pid` live in the OS). New variant; requires typespec extension. |

**Typespec extension** at `apps/ezagent_core/lib/esr/kind.ex:28-31`:

```
@type persistence_policy ::
        :ephemeral
        | {:snapshot, :on_change}
        | {:snapshot, :periodic, ms :: pos_integer()}
        | :on_terminate
        | :external
```

`Ezagent.Kind.Snapshot.load_or_init/3` and `maybe_save/4` get matching new clauses. `:on_terminate` is mostly handled in `Server.terminate/2` (which calls `Snapshot.save_now/3`, a new helper), not in `maybe_save/4` (which becomes a no-op for `:on_terminate`).

---

### 2.F Periodic strategy — Scheduler shape

Two options for the periodic timer:

1. **Per-Kind self-timer:** `Server.init/1` schedules `Process.send_after(self(), :snapshot_tick, ms)` if persistence is periodic; `handle_info(:snapshot_tick, state)` writes + re-schedules. **Pro:** no central scheduler, naturally distributed, dies with the Kind. **Con:** N Kinds = N timers (cheap in BEAM, but not zero).
2. **Central `Ezagent.Snapshot.Scheduler` GenServer:** holds list of `{pid, ms}` pairs, sends `:snapshot` casts on its own timer. **Pro:** one timer total. **Con:** central singleton, more failure modes, doesn't add real value over option 1.

**Spec recommendation: option 1 (per-Kind self-timer).** Aligns with BEAM idiom; `:snapshot_tick` is harmless if the Kind has already gone down. The "periodic" case is also the lowest-volume strategy in practice — Decision #27 lists it as a fit for "high-frequency-change Kinds where eventual consistency is OK," which today is zero Kinds. Implementation is ~10 LOC in `Server`.

---

### 2.G Versioning

The `version` column already exists. Two layers:

**Per-Kind `snapshot_version/0` optional callback** on `Ezagent.Kind`:

- Default: `0` (no version declared).
- Plugin author bumps when slice shape changes.
- Written into `row.version` on every save; read on every load.

**Per-Behavior `init_slice/2` upgrade hook** (optional, additive to existing `init_slice/1`):

- New optional callback: `upgrade_slice(loaded_slice, from_version, to_version)` on `Ezagent.Behavior`.
- Called only when `row.version < kind_module.snapshot_version()`.
- Default: identity (return `loaded_slice` unchanged) — many version bumps are additive (new key with sensible default via `Map.merge`).

**Phase 4 ships only the column + read-version-check.** Full upgrade machinery (declarative migration descriptors per slice) is Phase 5+. v1 contract: if you bump `snapshot_version/0` you also implement `upgrade_slice/3` on the affected Behavior, or you accept that loads of old versions will fail-loud (crash the Kind init → operator sees telemetry → manual snapshot-table truncate is the explicit remediation).

This intentionally leaves the door open without committing core to a heavy migration framework while there are zero real cases to design against.

---

### 2.H Concurrency + crash safety

| Threat                                                 | Sync `:on_change` behaviour                                                                                                              | Async `:periodic` behaviour                                                                                  |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| BEAM crash between slice update and write              | **Lost** — slice updated in `Server` state, return value gone with the process before sync write committed. Window: ~1ms.                | **Lost** — by definition; periodic accepts eventual loss.                                                    |
| SQLite write fails (disk full, locked, etc)            | Log + `[:ezagent, :persistence, :failed]` telemetry + return `{:ok, result}` to caller (in-memory state IS the truth until next write succeeds). | Same — `Snapshot.Writer` catches, logs, drops batch; next tick retries.                                      |
| Concurrent dispatch from multiple callers              | Serialised through `Ezagent.Kind.Server`'s single mailbox; no race.                                                                          | Same.                                                                                                        |
| Two Kinds in two BEAM nodes write to same `kind_snapshots` row | **Out of scope** — Phase 4 is single-node SQLite. KindRegistry already prevents two `Ezagent.Kind.Server` for the same URI in one node.    | Same.                                                                                                        |

The "BEAM crash loses ~1ms of `:on_change` writes" window matches Postgres' `synchronous_commit=off` semantics; production teams accept this. Documentation should call it out so the next developer doesn't try to add WAL/fsync gymnastics for a non-problem.

---

### 2.I Promotion plan — current Kinds → new strategies

| Kind                  | Today                       | Phase-4-completion target            | Why                                                                                                                                   |
| --------------------- | --------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `Ezagent.Entity.User`     | `{:snapshot, :on_change}`   | **Same** (now actually works)        | Identity slice (`caps`) is the durable identity. `:on_change` is correct: caps don't change every second, but when they do, they must persist. |
| `Ezagent.Entity.Workspace`| `:ephemeral`                | **Same**                             | Decision #109 — config IS the content, Loader rebuilds from `workspaces` table. Per-Kind snapshot would race the Store.                  |
| `Ezagent.Entity.Agent`    | `:ephemeral`                | `:on_terminate` (initially)          | Agent state today is mostly bridge-mapping (transient). What we *do* want to persist: any Identity caps an operator granted via `Identity.grant`. `:on_terminate` is the right fit: graceful shutdown saves; abrupt crash means the bridge will re-announce anyway. **Bump to `:on_change` in Phase 5 once Agent caps see real promotion volume.** |
| `Ezagent.Entity.Session`  | `:ephemeral`                | **Same**                             | Decision #91 — chat history is `MessageStore`, the only durable thing. Live members rebuild on boot (admin in `announce_ready`, agents on bridge reconnect). Already documented at `session.ex:14-23`. |

**Migration mechanics:** changing a Kind's `persistence/0` value is one line per Kind. No data migration needed (snapshots simply start being written from the next dispatch). User's existing in-memory caps are lost on the deploy that flips this, but they were ALWAYS being lost on every deploy before — net win.

---

## 3. UX (operator + end-user)

**End user:** invisible. State just persists. Today: restart the cluster, admin's granted caps to a new operator are gone — operator notices, has to re-grant. After this PR: restart, caps stay. The single test "after restart, the user-grants from yesterday still match" is the user-facing acceptance bar.

**Operator:**

- New `/admin/snapshots` LV section (Phase 5 work, not this PR) eventually shows table rows: URI, kind_type, slice size, last-update age. Operators can `mix ezagent.snapshot.dump <uri>` to inspect a single row, `mix ezagent.snapshot.clear <uri>` as the nuclear option for a poisoned slice. **Phase 4 ships zero UI** — telemetry events + raw `EzagentCore.Repo.get(KindSnapshot, uri)` is enough; if it gets used in anger, the LV view follows.
- Telemetry: `[:ezagent, :persistence, :restored]` on boot, `[:ezagent, :persistence, :written]` on each `:on_change` save, `[:ezagent, :persistence, :failed]` on write failure. All routed through the existing audit fan-out (`Ezagent.Audit` would need to add these three events to its `@events` list — 3 line delta).

---

## 4. Dev-author experience

A plugin author writing a new Kind that needs durability:

1. In `MyPlugin.MyKind`, set `def persistence, do: {:snapshot, :on_change}` (or whichever strategy fits).
2. That's it.

What they do NOT touch: `Snapshot` module, the migration, the Server lifecycle, anything Repo-related. The dirty check, write, restore, version handling are all automatic from the `persistence/0` declaration.

**Caveat for authors:** slices must be `term_to_binary`-roundtrippable. PIDs and refs are not — if a slice carries a `pid` (e.g. a bridge monitor), authors must either (a) re-establish it in `init_slice/1` after restore (the common pattern; see `Ezagent.Behavior.Identity` which holds only data) or (b) exclude that field from the slice (move into Process dictionary or a sibling ETS). Document this in the `Ezagent.Kind.Snapshot` moduledoc.

---

## 5. Decision questions for Allen

| #  | Question                                                                                                                                                                                                                                                                                                                                                              | Default if you don't answer                                                                                                              |
| -- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Q1 | **Storage encoding: JSON (`:map` column) or `term_to_binary` (`:binary` column)?** JSON is human-readable + portable but lossy for `MapSet`/`URI`/`DateTime`/atoms (needs per-slice custom encoder). `term_to_binary` is opaque-blob but lossless and zero ceremony per Behavior. The current `:map` column would force every slice author to write a Jason `Encoder` impl. | `term_to_binary` (`:binary` column). Add JSON view later as a `/admin` decoder if observability needs it. The cost of "I added a `MapSet` and snapshot silently dropped it" is too high. |
| Q2 | **Sync vs async write for `:on_change`?** Sync = ~1ms latency on dispatch return, zero loss within process lifetime. Async (via `Ezagent.Snapshot.Writer` mirroring `Audit.Writer`) = no latency, up to `@flush_interval_ms` (100ms) of loss on BEAM crash. | **Sync for `:on_change`.** Async for `:periodic`. Split keeps the high-value case durable; the high-volume case fast.                    |
| Q3 | **Snapshot write failure: log+continue or crash the Kind?** Memory `feedback_let_it_crash_no_workarounds` argues for crash. Counter: dispatch already returned a value to the caller; crashing on the next line is a workaround for an unrelated downstream concern, and the next write will retry. | **Log + telemetry + continue.** Crash is wrong here — let_it_crash applies to *invariant violation*, not external resource failure (disk full). |
| Q4 | **Per-Kind vs per-slice rows.** Spec recommends per-Kind (one row per URI, full slice map blob). Per-slice (one row per `(uri, slice_key)`) becomes attractive only when individual slices exceed ~50KB. Phase 4 has no such Kinds. | Per-Kind. Public API stable across this internal choice — Phase 5+ can split with a backfill migration if anything ever justifies it.    |
| Q5 | **Restore-after-rename semantics for added Behaviors.** Spec recommends `Map.merge(fresh_init, loaded_snapshot)` so newly-added Behaviors get fresh slices while existing Behaviors restore from disk. Alternative: fail-loud (crash init if Behavior count mismatch). | Merge with fresh defaults. Plugin authors adding a Behavior shouldn't need a snapshot migration for the additive case.                    |
| Q6 | **Should `:external` Kinds have a callback hook** (`load_external/2`) on the Kind module that `Server.init/1` calls instead of `init_slice`? Or do plugin authors just write a richer `init_slice/1` that does its own foreign-system read? | Plugin authors handle it in `init_slice/1`. Adding a hook is API surface for one Kind (the future PTY Agent); not worth it until there are 2+ callers. |
| Q7 | **Version bump policy.** When a Kind bumps `snapshot_version/0`, must the affected Behavior implement `upgrade_slice/3`? Or can we accept "load fails on old version → operator truncates → fresh init"? | Accept fail-loud for v1. Full upgrade framework is Phase 5+. Document the truncate remediation in the moduledoc.                          |
| Q8 | **`Ezagent.Audit` event extension.** Spec wants `[:ezagent, :persistence, :restored | :written | :failed]` routed through the existing audit fan-out (Phoenix.PubSub broadcast + SQLite via Writer). Confirm OK to extend `Ezagent.Audit.@events`? Alternative: separate `Ezagent.Snapshot.Telemetry` module — slight overlap with Audit's role. | Extend `Ezagent.Audit.@events`. Persistence events are operational audit events; same audience.                                              |

---

## 6. Test strategy

| Test                                                                                                  | Location                                                                                                       | Asserts                                                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Ezagent.Kind.Snapshot` unit (extend existing)                                                            | `apps/ezagent_core/test/esr/kind/snapshot_test.exs`                                                                | Replace `:save_skipped_phase1` assertion with `[:ezagent, :persistence, :written]` + Repo row check; add load-roundtrip test (write `MapSet`, load, assert `MapSet`); add `:on_terminate` and `:external` branches. |
| `Ezagent.Kind.Server` integration                                                                         | `apps/ezagent_core/test/esr/kind/server_test.exs` (extend)                                                         | After `handle_call` returns, `EzagentCore.Repo.get(KindSnapshot, uri)` row matches new state. After `terminate(:normal)`, `:on_terminate` Kind has its row written.                          |
| Restart roundtrip (integration) ★                                                                     | `apps/ezagent_core/test/integration/snapshot_restart_test.exs` (new)                                               | Spawn User Kind, dispatch `Identity.grant` to add a cap, send `:shutdown` to Server, spawn fresh User Kind under same URI, assert `Identity.list_caps` returns the granted cap.        |
| All 4 strategies covered                                                                              | same file                                                                                                      | Parametric over `[:ephemeral, {:snapshot, :on_change}, {:snapshot, :periodic, 50}, :on_terminate]` using a `Ezagent.Test.SnapKind` inline test Kind module. `:external` test is a stub that confirms `load_or_init` does NOT touch Repo. |
| Snapshot version mismatch (loud crash)                                                                | `apps/ezagent_core/test/esr/kind/snapshot_test.exs`                                                                | Insert row with `version: 999`, declare Kind with `snapshot_version: 0`, assert `Server.init` crashes with documented reason atom. (v1 — Phase 5+ adds upgrade test.)                  |
| Snapshot write failure does NOT crash dispatch                                                        | `apps/ezagent_core/test/esr/kind/snapshot_test.exs`                                                                | Mock Repo to raise on insert; dispatch returns `:ok` to caller; `[:ezagent, :persistence, :failed]` telemetry fires.                                                                       |
| `term_to_binary` safe-decode                                                                          | `apps/ezagent_core/test/esr/kind/snapshot_test.exs`                                                                | Hand-craft a binary that would create an unknown atom; assert load fails safely (does NOT crash BEAM, does NOT create the atom).                                                       |
| **Phase 4 invariant test (architectural gate)** ★★                                                    | `apps/ezagent_core/test/integration/snapshot_restart_test.exs`                                                     | The "restart roundtrip" above IS the architectural gate per memory `feedback_completion_requires_invariant_test`. Concrete restatement: *"Granting a cap to a User survives a Kind process restart."* If this fails, Decision #27's `:on_change` promise is unfulfilled regardless of unit-test green. |

★★ This single test is the completion criterion for the Snapshot strand of Phase 4. Don't claim done until it passes.

---

## 7. LOC estimate

| File                                                                                              | New / Δ | LOC      |
| ------------------------------------------------------------------------------------------------- | ------- | -------- |
| `apps/ezagent_core/lib/esr/kind/snapshot.ex` (real Repo read/write, version check, merge logic, new strategies) | Δ (substantial rewrite, but the public API holds) | ~150 (replacing 96 LOC of skeleton) |
| `apps/ezagent_core/lib/esr/snapshot/writer.ex` (async writer for `:periodic`, mirrors `Audit.Writer`) | New     | ~100     |
| `apps/ezagent_core/lib/esr/kind.ex` (typespec extension + `snapshot_version/0` optional callback)     | Δ       | +10      |
| `apps/ezagent_core/lib/esr/kind/server.ex` (periodic timer in init + handle_info, terminate hook for `:on_terminate`, write-failure handling) | Δ       | +50      |
| `apps/ezagent_core/lib/esr/behavior.ex` (`upgrade_slice/3` optional callback)                         | Δ       | +5       |
| `apps/ezagent_core/lib/esr/ecto/kind_snapshot.ex` (Ecto schema — currently none, Repo.get needs it)   | New     | ~30      |
| `apps/ezagent_core/priv/repo/migrations/<ts>_phase4_kind_snapshot_binary.exs`                         | New     | ~30      |
| `apps/ezagent_core/lib/esr/audit.ex` (add 3 persistence events to `@events`)                          | Δ       | +3       |
| `apps/ezagent_core/lib/ezagent_core/application.ex` (start `Ezagent.Snapshot.Writer` in sup tree)             | Δ       | +1       |
| `apps/esr_plugin_chat/lib/esr/entity/agent.ex` (flip `:ephemeral → :on_terminate`)                | Δ       | +1 / −1  |
| **Subtotal impl**                                                                                 |         | **~330** |
| Tests (snapshot_test extension + server_test extension + new snapshot_restart_test integration)   | New + Δ | ~250     |
| **Total**                                                                                         |         | **~580** |

Fits comfortably under the per-PR red line (Decision #72 / 1100 LOC). Tests are roughly 75% of impl, weighted toward the restart roundtrip integration test.

---

## 8. What worries me (read this last)

1. **The `state :map` → `state_binary :binary` column add is the riskiest single change.** Ecto's `:map` adapter for SQLite stores JSON; binary needs `:binary` type and `Ecto.Type` handling at the schema layer. If anyone has a half-written PR touching `kind_snapshots` they'll conflict. Mitigation: this is a 30-LOC migration, easy to rebase. Worth scanning open branches before merging.

2. **`:erlang.binary_to_term(_, [:safe])` rejects atoms not yet loaded.** If a Kind's slice carries an atom that exists in the writing-time codebase but not the reading-time codebase (e.g. operator restored a snapshot taken on a newer build), load fails. This is correct behaviour (security), but the error message is currently `:badarg` — needs a `rescue ArgumentError -> {:error, :unsafe_atom}` wrapper with a helpful log. Trivial; flagging so reviewer asks for it.

3. **Periodic-strategy self-timer survives Kind death.** `Process.send_after(self(), :snapshot_tick, ms)` sends to `self()`; when the Kind dies the timer-message goes nowhere. Safe. Just noting in case anyone wonders about leaked timers.

4. **`Ezagent.Entity.Agent` flip to `:on_terminate` changes a Phase 2/3 invariant** (that Agents are fully ephemeral). Tests asserting "fresh Agent has empty caps after restart" will need updating because granted caps now survive a graceful restart. Spec considers this a feature, not a regression — but worth a heads-up.

5. **No coordination with Decision #109's Workspace persistence.** Re-emphasising §0: Workspace's `config` lives in `workspaces` table via `Ezagent.Workspace.Store`; the Workspace Kind itself stays `:ephemeral`. If a future spec ever wants to give Workspace runtime state too (e.g. last-instantiated-at timestamp), that state goes through *this* spec's `kind_snapshots` table, parallel to (not replacing) the Store. Clean separation; this spec deliberately does not perturb #109.

6. **Phase 5 will want `mix ezagent.snapshot.{dump,clear,list}` and a `/admin` LV view.** Not in this spec, but the `Ezagent.Snapshot.Writer` shape, `KindSnapshot` Ecto schema, and telemetry events are all chosen so those Phase 5 additions are pure read-side and never need to touch core.

---

**END SPEC.** Awaiting Allen's answers to Q1–Q8 before implementation begins.
