# Test-Isolation Race (ezagent #52) — Root-Cause Diagnosis & Fix Design

**Status:** DESIGN / PLAN (no production or test code changed by this document).
**Worktree:** `/private/tmp/p52-plan` @ branch `plan-test-isolation-race`, off `origin/main` `e689c91e`.
**Date:** 2026-06-13.
**Issue title:** "SQLite lock + boot-singleton sandbox-owner-exit crash" (umbrella test-isolation race).

---

## 0. TL;DR

The issue title conflates **three independent failure modes**. Reproduction on this
fresh worktree (per `feedback_fresh_worktree_for_test_measurement`) pins each one
precisely, and the headline symptom (large standalone failure counts) turns out to be
**mostly NOT an ownership race**:

| # | Failure mode | Standalone count | Umbrella count | True nature |
|---|---|---|---|---|
| **A** | `UndefinedFunctionError … (module … is not available)` | **~135 of 148** | **0** | Test/code-path **layering**: tests reference sibling-app modules absent from the standalone code path. NOT a DB race. |
| **B** | `DBConnection.OwnershipError` / `snapshot_exists?: … raised` / `EventLog.append failed (… cannot find ownership process)` | ~7 | **8 / 14 / 6 (present even when umbrella is GREEN)** | Genuine **ownership gap**: boot-singletons + `(:proc_lib)`-spawned Kinds/Tasks run `Repo` queries outside any test's `$callers` chain. Currently surfaces as **async log noise** (rescued), not assertion failures. |
| **C** | `Exqlite.Connection … failed to connect: database is locked` | 3 | **3 (present even when umbrella is GREEN)** | SQLite **single-writer lock** under the 20-slot pool. Distinct from B (a connect-time lock, not an ownership error). WAL + 2 s `busy_timeout` are SQLite3-adapter DEFAULTS and ARE active — the lock is write CONTENTION exceeding 2 s (pool_size 20 + the Mode-B boot-writer), NOT missing config (codex correction). |

**Measured this session:**
- `cd apps/ezagent_core && mix test --seed 0` → **1584 tests, 148 failures** (logs `/tmp/p52_core_standalone.log`).
- `mix test apps/ezagent_core/test --seed 0` (umbrella root) → **1584 tests, 0 failures** — but with **8 OwnershipError + 14 cannot-find-ownership + 6 EventLog.append-failed + 3 database-is-locked** log lines still emitted (logs `/tmp/p52_core_umbrella.log`).
- Single file `resolver_db_test.exs`: standalone **10 tests / 10 failures** (all `Ezagent.Users.create/3 is undefined`); umbrella **10 tests / 0 failures**.

**Conclusion:** Mode **A** is the standalone failure count — it is a *test-suite-design / code-path-loading* fact, not a sandbox race, and "fixing" it by making standalone go green is **not the right goal** (these tests legitimately need sibling apps; the umbrella is the supported run mode). Modes **B** and **C** are the *real* `#52` race — they survive into the green umbrella run as log noise and are the source of the **intermittent** failures (the cli_lv cross-BEAM flake; cold-restart gate flakes the DataCase moduledoc already documents). The recommended fix targets **B and C at the root** and **re-scopes A** as "not a bug to chase."

---

## 1. Reproduction commands (fresh worktree)

```bash
# fresh worktree; deps + test DB
cd /private/tmp/p52-plan
mix deps.get && MIX_ENV=test mix compile
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate

# Mode A + B + C, standalone (the headline symptom):
( cd apps/ezagent_core && MIX_ENV=test mix test --seed 0 )      # 148 failures

# Same suite, umbrella (supported mode): 0 failures, but grep the log:
MIX_ENV=test mix test apps/ezagent_core/test --seed 0 2>log
grep -c "is not available"                 log   #  Mode A → 0 in umbrella
grep -c "cannot find ownership process"    log   #  Mode B → ~14 (noise, green)
grep -ci "database is locked"              log   #  Mode C → ~3  (noise, green)

# Isolate Mode A cleanly (one DB-touching file):
( cd apps/ezagent_core && MIX_ENV=test mix test test/ezagent/credential/resolver_db_test.exs )  # 10/10 fail: Ezagent.Users undefined
MIX_ENV=test mix test apps/ezagent_core/test/ezagent/credential/resolver_db_test.exs            # 0 fail
```

> **Per-worktree DB drift caution** (`feedback_fresh_worktree_for_test_measurement`):
> `config/test.exs` points the Repo at `apps/ezagent_core/../ezagent_core_test.db`
> (worktree-local). Standalone (`cd apps/ezagent_core`) and umbrella-root both resolve
> to the SAME file. After bisecting, `MIX_ENV=test mix ecto.drop && ecto.create &&
> ecto.migrate` to reset. All numbers above were taken on this clean worktree.

---

## 2. Root cause — precise mechanism

### 2.1 Mode A — sibling-app module not on the standalone code path (the 135/148)

`apps/ezagent_core/test/**` contains cross-cutting suites (e2e scenarios, integration,
invariants, credential/workspace/session tests) that call into modules **defined in
sibling umbrella apps**, e.g.:

| Referenced in `ezagent_core/test` | Defined in (sibling app) |
|---|---|
| `Ezagent.Users`, `Ezagent.Entity.User` | `apps/ezagent_domain_identity/lib/ezagent/{users,entity/user}.ex` |
| `Ezagent.Workspace.Store`, `Ezagent.Workspace` | `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex` |
| `Ezagent.Entity.Session`, `Ezagent.Behavior.Session` | `apps/ezagent_domain_instance_message/lib/ezagent/{entity,behavior}/session.ex` |

`ezagent_core`'s `mix.exs` does **not** depend on these sibling apps (and must not —
the three-tier rule keeps `core` below `domain`). When you `cd apps/ezagent_core &&
mix test`, Mix only loads `ezagent_core` + its declared deps, so those modules are
literally not on the BEAM code path → `UndefinedFunctionError … is not available`.
In the umbrella run, every sibling app's `ebin` is loaded, so they resolve.

**Evidence:** `resolver_db_test.exs` → 10/10 standalone failures, *every one*
`function Ezagent.Users.create/3 is undefined (module Ezagent.Users is not
available)`; the same file is 0/10 in umbrella. The top standalone error histogram is
dominated by `… is not available` (≈135 lines) with only ≈7 true `OwnershipError`s.

This is **not a sandbox race**. It is "running a cross-tier suite outside the only
context that can satisfy its dependencies." The fix is *not* to make standalone green.

### 2.2 Mode B — boot-singleton + out-of-`$callers` Kind ownership gap (the real race)

The sandbox model in this repo:

- `apps/ezagent_core/test/test_helper.exs`: `Sandbox.mode(EzagentCore.Repo, :manual)`.
- `EzagentCore.DataCase.setup_sandbox/1` (`data_case.ex:78`): non-async tests get a
  **shared owner Agent** via `start_owner_stable!(true)` — checks out a connection,
  `Sandbox.mode(Repo, {:shared, owner})` (with a 500-attempt `:already_shared` retry
  loop, `data_case.ex:130-167`), and `Sandbox.allow(Repo, owner, test_pid)`. Async
  tests get `start_owner!(shared: false)` (per-connection `allow`).
- Repo: `Ecto.Adapters.SQLite3`, pool `Ecto.Adapters.SQL.Sandbox`, `pool_size: 20`
  (`config/test.exs:20`).

The ownership gap has two sources, both **outside the test process's `$callers` chain**,
so neither shared-allow nor `Sandbox.allow/3` reaches them:

1. **Boot-singletons started under the app supervisor, before any test owner exists.**
   `EzagentCore.Application.start/2`:
   - `register_system_kind/0` (`application.ex:142,226`) → `SpawnRegistry.spawn(system://routing/default)`
     → `Kind.Server.init/1` (`server.ex:104`) runs `Snapshot.load_or_init` (a
     `kind_snapshots` **read**) and `persist_initial_snapshot/3` (`server.ex:211`, a
     **write**). At boot there is no sandbox owner; the manual-mode pool has no
     allowed process for this supervisor-tree pid.
   - The boot path **already swallows** the resulting error: `persist_initial_snapshot`
     wraps `save_now` in `rescue`/`catch :exit` (`server.ex:240-246`), and
     `StateRebuilder.snapshot_exists?/1` (`state_rebuilder.ex:236-252`) rescues the
     `OwnershipError` and logs *"snapshot lookup raised … — treating as
     not-existing."* This is **why the umbrella run is green despite the error** — the
     singleton degrades silently. But it means every boot logs the noise, and in the
     **cold-restart gate tests** (`SandboxColdRestartTest`, `LifecycleTest "THE GATE"`,
     etc., documented at `data_case.ex:100-129`) a restarted `:snapshot` Kind reads
     `kind_snapshots` in `init/1` *before* it registers in `KindRegistry`, so the test
     cannot `Sandbox.allow/3` it ahead of the read — its ONLY route is shared mode, and
     a reverted/foreign share raises and flunks the gate. That is the real
     intermittency `#52` is about.

2. **Kinds / Tasks spawned during a test but **detached** from its caller chain.**
   The umbrella green run still logs `Ezagent.Kind.Runtime: :emit EventLog.append
   failed (continuing): … cannot find ownership process for #PID<…> (:proc_lib)`
   (`/tmp/p52_core_umbrella.log:81`). `(:proc_lib)` (not the test module) confirms the
   query runs in a process whose `$callers` does not include the test pid — e.g. a
   `Kind.Server` under a **global** `DynamicSupervisor` (`Ezagent.KindSupervisor`,
   `Ezagent.Core.SingletonSupervisor`) doing a `handle_continue`/`handle_info`
   snapshot/event write *after* the test body returned. `EventLog.append` and
   `Kind.Runtime :emit` also rescue/continue, so again: noise in green runs, flake in
   teardown-sensitive runs. The DataCase's P6 `drain_live_kinds/0` + `start_owner_stable!`
   retry are **mitigations already in place** for exactly this class — they reduce but
   do not eliminate it (a late PubSub fan-out can still land a `handle_info` after the
   final drain pass; see `data_case.ex:169-211`).

**Net:** Mode B is an *ownership-coverage* gap for DB work that happens (a) at app boot
under the supervisor tree, and (b) in globally-supervised Kinds whose work outlives or
detaches from the owning test. The production code already **rescues** it everywhere, so
it manifests as log noise + cold-restart-gate / cross-BEAM flakiness rather than
deterministic failure.

### 2.3 Mode C — SQLite single-writer lock at connection establishment

`Exqlite.Connection (#PID<…> ("db_conn_N")) failed to connect: ** (Exqlite.Error)
database is locked` (`/tmp/p52_core_umbrella.log:160-162`). This is **not** an
ownership error — it is a pool connection *failing to open* because another connection
holds SQLite's database-level write lock. Contributing factors:

- `pool_size: 20` (`config/test.exs:20`) → up to 20 connections racing to open against
  one SQLite file (high for a single-writer DB).
- **CORRECTION (codex review):** the earlier draft claimed "no `busy_timeout`/WAL
  configured." That is misleading. `EzagentCore.Repo` uses `Ecto.Adapters.SQLite3`
  (`repo.ex:4`), whose Exqlite layer DEFAULTS `journal_mode: :wal` and `busy_timeout:
  2000` ms — and `config/test.exs` adds NO override disabling them. So WAL + a 2 s busy
  timeout are ALREADY ACTIVE. The lock therefore happens **despite** WAL/timeout: a
  contending writer waited the full 2 s and still couldn't acquire the write lock →
  `database is locked`. The root cause is genuine write CONTENTION exceeding 2 s, driven
  by (a) `pool_size: 20` and (b) extra unsynchronized writers — chiefly the Mode-B
  boot-singleton writing `kind_snapshots` at boot outside any test's serialization, plus
  `:proc_lib`-spawned Kinds writing after a test body returns. It is NOT "missing config."

In the sandbox, writes are serialized per-test, so this rarely fails an assertion — but
it is a real, separable lock contention that becomes a hard failure under heavier
concurrency (and is the "SQLite lock" half of the issue title).

---

## 3. Fix options (with tradeoffs)

For Mode A (standalone count) the only sane "fix" is **re-scoping** (3.0). The
substantive options (3.1–3.5) target Modes B and C.

### 3.0 (Mode A) Re-scope: standalone cross-tier suites are out of contract — do NOT chase green standalone

Make explicit (in `CONTRIBUTING` / the suite docs / `#52` resolution note) that the
supported test command is `mix test` from the umbrella root (already the only path in
the `precommit` alias, `mix.exs:121`), and that `cd apps/X && mix test` is valid ONLY
for a leaf app whose tests reference no sibling modules. Optionally tag the cross-tier
suites (`@moduletag :umbrella_only`) and `--exclude umbrella_only` would be a no-op in
umbrella but document intent. **Does it fix root cause?** It corrects the *framing* —
Mode A is not a defect. **Blast radius:** docs + optional tags. **Risk:** none. **Repo
pattern:** matches the three-tier rule (`core` cannot depend on `domain`, so its tests
legitimately can't run standalone). *This is the recommended treatment for A.*

### 3.1 (Mode B) Make the boot-singleton sandbox-aware: don't spawn DB-touching singletons at boot in `:test`

`register_system_kind/0` already runs unconditionally at boot. Gate the *eager spawn*
of `system://routing/default` behind `is_test?()` (the same predicate `application.ex`
already uses to skip `Audit.Writer` / `Snapshot.Writer`, `application.ex:201-204`), and
let it spawn **lazily** on first dispatch (the dispatch path already lazy-spawns via
`SpawnRegistry.spawn/1` + `snapshot_exists?`, `invocation.ex:190,236`). Tests that need
the routing sentinel `Sandbox.allow/3` it (or spawn it inside a checked-out test).

- **Root cause?** Yes for the boot half of B — removes the *no-owner-at-boot* read/write entirely.
- **Blast radius:** one boot call + the registration stays (only the eager `spawn` is deferred). The lazy path already exists and is exercised.
- **Risk:** a test that assumes `system://routing/default` is pre-spawned would need an explicit spawn; low, greppable.
- **Repo pattern?** Yes — identical to the existing `@writers_skipped_in_test` precedent and the `Ezagent.Test.AuditCase` opt-in (`server.ex` / `application.ex` already do this for the two writers).

### 3.2 (Mode B) `Sandbox.allow/3` the global Kind supervisors / boot-spawned Kinds onto the test connection

In `DataCase.setup_sandbox`, after acquiring the owner, walk `KindRegistry.list_all/0`
(already used by `drain_live_kinds/0`) and `Sandbox.allow/3` each live Kind pid onto the
owner connection; and/or allow the global `DynamicSupervisor`s so their children inherit
via `$callers`.

- **Root cause?** Partial. It covers Kinds *already alive at setup time*, but NOT Kinds
  spawned later in the test under a global supervisor (the `(:proc_lib)` case) — those
  appear after the `allow` pass, and the cold-restart gate's restarted pid reads
  `kind_snapshots` **before** it is in `KindRegistry`, so it can never be enumerated/
  allowed ahead of its first read (this is exactly the failure `data_case.ex:100-113`
  documents).
- **Blast radius:** DataCase only.
- **Risk:** races with spawn timing; the cold-restart class remains. Tightens the existing P6 mitigation but doesn't close it.
- **Repo pattern?** Yes (`Sandbox.allow/3` already used in `AuditCase`, `start_owner_stable!`).

### 3.3 (Mode B) Dedicated long-lived shared-sandbox owner that outlives individual tests

Start one `:shared`-mode owner in `test_helper.exs` (a process that lives for the whole
suite) so boot-singletons and globally-supervised Kinds always see a shared connection,
instead of per-test owners that come and go.

- **Root cause?** Yes for B — a stable shared owner means the pool is never reverted to
  `:manual` mid-test, killing the cold-restart revert race at its source.
- **Blast radius:** large — forces **`async: false` suite-wide** (shared mode is
  incompatible with async, per the testing reference §"Async gotchas" #5). 181 DataCase
  files + 72 bare-checkout files currently include `async: true` suites; this would
  serialize the entire suite (the 29.5s async portion becomes sequential).
- **Risk:** big runtime regression; loses per-test rollback isolation guarantees if not
  careful; conflicts with the existing per-test `start_owner_stable!` design.
- **Repo pattern?** No — repo deliberately uses per-test owners + shared-only-for-non-async. Rejected as the primary fix.

### 3.4 (Mode B, mitigation only) Mark the offending suites `async: false`

Force the cold-restart-gate / cross-BEAM / Kind-spawning suites to `async: false`.

- **Root cause?** No — it reduces *concurrency-induced* revert windows but the boot
  singleton still reads with no owner; it's a probability reduction, not a fix.
- **Blast radius:** the tagged suites only.
- **Risk:** false sense of safety; runtime cost; the gate can still flake on a foreign
  shared owner. Use only as a belt-and-braces alongside 3.1.
- **Repo pattern?** Some suites already do this; consistent but insufficient alone.

### 3.5 (Mode C) Reduce write contention; RAISE busy_timeout above the 2 s default (WAL already on)

**CORRECTED (codex):** WAL + 2 s `busy_timeout` are already active (SQLite3-adapter
defaults; `config/test.exs` overrides neither). So the lever is NOT "add WAL" — it is
to (a) REMOVE the chief unsynchronized contending writer, which is the **Mode-B
boot-singleton** (fix 3.2 already does this — gating the boot-spawn out of `:test`
eliminates the boot-time `kind_snapshots` writer that races the pool), and (b) tune for
the single-writer reality: raise `busy_timeout` ABOVE the 2 s default (e.g. `5_000`) via
the explicit `EzagentCore.Repo` test config, and reduce `pool_size: 20` (under the
sandbox each test owns one connection, so a 20-slot pool mostly adds connect-time lock
contention). Mode C is thus largely SUBSUMED by fix 3.2 plus a small config tune — it is
not an independent "missing pragma" fix.

- **Root cause?** The contention root is shared with B (the boot-writer); the residual
  config tune (longer `busy_timeout`, smaller pool) makes a contending writer *wait* instead of
  immediately raising "database is locked"; WAL lets readers proceed during a write.
- **Blast radius:** config only; affects all SQLite connections.
- **Risk:** low and well-understood; WAL is the standard SQLite-under-concurrency
  recommendation. Must verify the sandbox + WAL interaction (WAL is fine with the
  sandbox; the sandbox wraps each test in a transaction regardless of journal mode).
- **Repo pattern?** New (no pragmas today) but idiomatic for SQLite + Ecto.

---

## 4. Recommended approach

A **combined, root-targeted** fix — **3.0 + 3.1 + 3.5**, with **3.2 as a tightening of
the existing DataCase mitigation** and **3.4 explicitly NOT pursued** (mitigation, not
fix):

1. **3.0 — Re-frame Mode A.** Document that the umbrella root is the supported test
   command; cross-tier suites are `:umbrella_only` by construction. This dissolves
   ~135/148 of the headline standalone failures as *not a bug*. (Gate: standalone count
   is no longer the success metric; umbrella green is.)
2. **3.1 — Stop spawning the boot DB-singleton in `:test`.** Gate the eager
   `SpawnRegistry.spawn(system://routing/default)` in `register_system_kind/0` behind
   `is_test?()`, mirroring the `@writers_skipped_in_test` precedent; keep the Behavior
   *registration* (no DB touch); rely on the existing lazy-spawn dispatch path. This
   removes the **no-owner-at-boot** read/write — the source of the 7 boot-time
   `snapshot_exists?: … raised` lines and the cold-restart-gate's pre-registration read.
3. **3.5 — RAISE `busy_timeout` above the 2 s default + trim test `pool_size` (WAL already on).**
   Mode-C "database is locked" is largely SUBSUMED by fix 3.1/3.2 (removing the boot-writer);
   the residual config tune (longer busy_timeout, smaller pool) handles leftover contention.
   NOT "add WAL" — WAL + 2 s busy_timeout are SQLite3-adapter defaults already active (codex).
4. **3.2 — Tighten DataCase:** after `start_owner_stable!`, `Sandbox.allow/3` every
   currently-live `KindRegistry` pid onto the owner connection (cheap, reuses the
   `registered_kinds/0` helper already present for draining). This shrinks the
   `(:proc_lib)` EventLog-append noise for Kinds alive at setup. (The residual
   spawned-mid-test class is already best-effort-drained by P6; combined with 3.1 the
   cold-restart gate no longer depends on a foreign share.)

**Why this set:** It attacks each *distinct* mechanism at its own root (boot singleton →
3.1; SQLite lock → 3.5; framing of A → 3.0), reuses the repo's established
`is_test?()` / `AuditCase` / `Sandbox.allow` patterns (low blast radius, no new
architecture), and avoids the global `async: false` regression of 3.3 and the
band-aid nature of 3.4. It honors `feedback_let_it_crash_no_workarounds`: 3.1 *removes*
a degraded boot path rather than adding another rescue/default.

### 4.1 Step-by-step implementation plan (for the FUTURE fix PR — not done here)

| Step | File | Change |
|---|---|---|
| S1 | `apps/ezagent_core/lib/ezagent_core/application.ex` | In `register_system_kind/0`, wrap the `SpawnRegistry.spawn(uri)` eager-spawn block (`:250-255`) in `if not is_test?()`. Keep the `CapabilityRegistry.register` + `SpawnRegistry.register("system", …)` (no DB). |
| S2 | `apps/ezagent_core/test/support/` (or DataCase) | For any test asserting `system://routing/default` is pre-live, add an explicit `SpawnRegistry.spawn/1` inside the checked-out test (greppable: `routing_default_uri`). |
| S3 | `config/test.exs` | RAISE `busy_timeout` to `5_000` (above the 2 s adapter default) on the `EzagentCore.Repo` test config; reduce `pool_size` 20→`10` (measure). WAL is already the adapter default — do NOT re-add it expecting it to be the fix. The boot-writer removal (S2) is the primary Mode-C lever. |
| S4 | `apps/ezagent_core/lib/ezagent_core/data_case.ex` | In `setup_sandbox/1`, after `start_owner_stable!`, `Enum.each(registered_kinds(), fn {_uri, pid} -> Sandbox.allow(Repo, owner_or_test, pid) end)`. (Reuse `registered_kinds/0`.) |
| S5 | docs | Add the `#52` resolution note + `:umbrella_only` framing (3.0). |
| — | invariant test | Add a regression test (see §5) that FAILS if the boot singleton spawns in `:test` or if a green umbrella run emits a `cannot find ownership process` for `system://routing/default`. |

### 4.2 The success gate (per `feedback_completion_requires_invariant_test`)

The architectural goal is *"no DB work runs without a sandbox owner in the test env."*
The gate test must FAIL when that is violated, not merely when the suite is red:

- **G1:** `mix test apps/ezagent_core/test --seed 0` (umbrella) emits **zero**
  `cannot find ownership process` and **zero** `snapshot_exists?: … raised` and **zero**
  `database is locked` lines (assert on `capture_log` over a representative boot +
  cold-restart-gate run). Today it emits 14 / 7 / 3 respectively.
- **G2:** An invariant test asserts `EzagentCore.Application` does **not** eagerly spawn
  `system://routing/default` in `:test` (mirror of `audit_writer_test_env_isolation_test.exs`).
- **G3:** The cold-restart gate suite (`SandboxColdRestartTest`, `LifecycleTest "THE
  GATE"`, `PtyColdRestartTest`, `TerminableColdLoadTest`) passes across **≥20 seeds**
  with no flake (currently flakes ~half the seeds per the DataCase moduledoc).

No test may be made *falsely* green: G1 asserts on log *absence*, G2/G3 assert on
behavior, so a fix that merely widens a `rescue` or sleeps would not satisfy them.

---

## 5. Verification plan

1. **Baseline (this worktree, already captured):**
   - Standalone `apps/ezagent_core`: 148 failures (Mode A dominant).
   - Umbrella `apps/ezagent_core/test`: 0 failures, but 14/7/3 B/C log lines.
   - `resolver_db_test.exs`: 10/10 standalone (Mode A), 0/10 umbrella.
2. **After the fix PR (future):**
   - Re-run umbrella `mix test --seed 0` → 0 failures **and** G1 zero-noise assertion green.
   - Loop the cold-restart gate suite over seeds `0..20` (`for s in $(seq 0 20); do mix test <gate files> --seed $s; done`) → 0 flakes (G3).
   - Run the cli_lv cross-BEAM suite (`apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs`, `async: false`) ×20 seeds → 0 flakes.
   - Confirm Mode A: standalone count is **no longer the metric**; the `:umbrella_only`
     framing is documented and (optionally) tagged.
   - Run the full `mix precommit` (umbrella) → green, no new warnings.
3. **Per `feedback_fresh_worktree_for_test_measurement`:** take every before/after
   measurement on a **fresh worktree** with a freshly created+migrated test DB; reset
   (`ecto.drop && ecto.create && ecto.migrate`) between seed sweeps so per-worktree
   SQLite drift cannot masquerade as a regression.

---

## 6. Notes / non-goals

- **No production or test code was changed by this planning task.** Reproduction used
  only `mix test` runs against throwaway, gitignored per-worktree `_build`/`deps`/`.db`
  artifacts; the tracked tree is clean (`git status` shows no source modifications).
- The `let-it-crash` policy (`feedback_let_it_crash_no_workarounds`) steers us AWAY from
  3.3/3.4 (which add isolation knobs / degrade paths) and toward 3.1 (delete the
  degraded boot path). The *existing* rescues in `snapshot_exists?` / `EventLog.append`
  pre-date this design; 3.1 makes them unnecessary in `:test` rather than relying on them.
- Mode A's correct resolution is *framing*, not code: the three-tier rule
  (`core` cannot depend on `domain`) **guarantees** core's cross-tier tests can only run
  in umbrella. Treating the standalone failure count as the bug would invert the
  architecture.
