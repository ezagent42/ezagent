# CI flake diagnosis — `precommit + check_invariants` recurring reds

**Date:** 2026-06-27
**Author:** Claude (lead-assist), for Allen
**Scope:** Why nearly every PR's CI `precommit + check_invariants` job goes RED on the
same recurring failures even when the PR's own code is clean — forcing
admin-merge-after-flake-verification (contributing P5 / task #108) — and how to catch
it locally BEFORE pushing.

**Primary evidence:** the actual failing CI run for PR #1037
(`gh run view 28272814108 --log-failed`), the CI workflow
(`.github/workflows/ci.yml`), the test DB config (`config/test.exs`), the shared
test harness (`apps/ezagent_core/test/support/data_case.ex`), and the three flaky
suites' source. Reproduced locally (full umbrella) — see §3.

---

## TL;DR

There is **one** root cause with three symptoms, plus one independent latent bug.

1. **Root cause (shared-state #1, dominant):** the Ecto **SQL Sandbox shared-mode
   connection reverts to `:manual`** mid-run whenever a prior non-async test's owner
   process terminates. Globally-supervised Kinds and boot-time loaders run Repo
   queries **outside the test's `$callers` chain**, so once the pool has reverted they
   raise `DBConnection.OwnershipError: cannot find ownership process … (a connection's
   mode reverts to :manual if its owner terminates)`. This is all over the #1037 log.

2. **Symptom — `PluginIsolationWorkspaceTest` (the 2 hard failures in #1037):**
   the workspace the test created via `Workspace.create/2` appears in `Loader.load_all/0`
   but with **empty children**, so `load_all_until_present: workspace "invariant-…"
   never appeared in Loader results with children` flunks. The firing path (confirmed by
   grepping the #1037 log — see §1.2) is **`instantiate_via_dispatch/1`**: the Loader
   dispatches `:instantiate` to the workspace's Kind, which spawns/queries under a
   **global supervisor — outside the test's `$callers` chain** — so on the reverted pool
   it produces no live children. The 50-retry hardening (#734) does **not** help: the
   revert persists until a *new* shared owner is installed, so every retry sees the same
   empty children. (The `load_all/0` rescue that masks `OwnershipError` as `[]`
   (`loader.ex:406-416`) is a *second*, currently-dormant path — see §1.2 — that should
   be unmasked in `:test` defensively, but it is NOT what fired in #1037.)

3. **Symptom — `FsResolverTest` / `DefaultSessionTemplateSeedTest` / `AnonUserGCTest`:**
   same shared-mode-revert class, plus per-suite global-singleton churn (FsResolver
   `Registry` kill/restart of a `:protected` ETS table; reads of boot-seeded
   `workspace://system` rows written outside the sandbox; `GC.sweep` row deletes). They
   are `async: false` but that **only serialises within their own app's BEAM** — it does
   nothing about the reverted shared connection or rows other apps left in the shared PG
   DB.

4. **Independent latent bug (deterministic, not a flake):** the `ProbeBehavior` test
   fixture in `plugin_isolation_workspace_test.exs` **does not implement the now-required
   `required_caps/0` callback** (`behavior.ex:340`, not in `@optional_callbacks`). Today
   it is only a compile *warning*, but it is real contract drift that will become a hard
   failure if/when the callback is enforced. Fix it in the same pass.

**Fix priority (by leverage):**
1. **Allow the dispatched/spawned Kinds onto the test's sandbox owner** so the Loader's
   `:instantiate` dispatch (and the seed tests' spawned Session/Agent Kinds) never query
   on a reverted/foreign connection — AND make `EzagentCore.DataCase` re-establish shared
   mode deterministically so it can't revert mid-suite (extend `start_owner_stable!` to
   *hold* the share across owner `:DOWN`s). This is the path that actually fired in #1037
   (§1.2) and kills symptom #2 + most of #3 at the source. **Defensive companion:** stop
   `Loader.load_all/0` masking `OwnershipError` as `[]` in `:test` so the dormant path
   (a) can never silently swallow a broken connection.
2. **Per-suite isolation of the global singletons** that get killed/mutated
   (FsResolver `Registry`, SpawnRegistry) so a concurrent reader never sees a
   dead/empty table.
3. **Pre-push gate**: a one-line alias that runs *exactly* what CI runs against a
   private partitioned DB — a *catch-net*, not the cure. Because the flake is a timing
   race (the same seed is red on the ubuntu runner but green on macOS — see §3), a green
   local run does NOT guarantee a green CI run until fixes 1-2 land. The cure is fix
   1-2; the gate reduces blind pushes and makes admin-merge a conscious, verified choice.

**One-line pre-push command devs should run** (see §5):

```
MIX_ENV=test MIX_TEST_PARTITION=$USER mix ci.local
```

---

## 1. Root-cause per flake — the ACTUAL mechanism

### 1.0 The execution model (load-bearing)

`mix.exs` is an umbrella (`apps_path: "apps"`). Root `mix test` is a **recursive** Mix
task: it runs **once per child app, each in its own OS process / BEAM**, **sequentially**
(the CI log shows `==> ezagent_plugin_codex`, `==> ezagent_domain_external_mirror`, …
boundaries, each with its own `Running ExUnit with seed: 979933, max_cases: 8`).

Consequences that decide which mechanisms are even possible:

- **ETS singletons** (`:ezagent_spawn_registry`, `:ezagent_resource_fs_types`) live in
  one app-BEAM. Cross-app pollution through live ETS is **impossible** — pollution
  through those tables is **within-app only**.
- The **PostgreSQL test DB is the only cross-app shared state.** It is a **single** DB,
  `ezagent_pg_compat_test#{MIX_TEST_PARTITION}` (`config/test.exs:13`). CI sets **no**
  `MIX_TEST_PARTITION`, so every app's BEAM in a run shares the one DB
  `ezagent_pg_compat_test`. Rows one app writes (and boot seeds) are visible to the next.
- Within each app-BEAM, ExUnit runs `max_cases: 8` concurrently on the GitHub runner
  (8 logical cores). `async: false` suites still run **serially among themselves**, but
  concurrently with… nothing — and crucially they share **one** sandbox pool with the
  app's globally-supervised Kinds.

> **CI ≠ local difference that matters most:** CI runs the full umbrella with **no DB
> partition** and **`max_cases: 8`**; a dev running `cd apps/<one> && mix test` runs a
> single app with the cross-tier `:umbrella_only` suites silently excluded and a quieter
> pool. That is why "it passes in isolation": isolation removes both the prior-owner
> churn that reverts shared mode and the cross-app rows in the shared DB.

### 1.1 The Sandbox shared-mode revert (the engine behind all three)

`EzagentCore.DataCase.setup_sandbox/1` checks out in **shared** mode for every
non-async test (`shared: not tags[:async]`). The harness already documents (and partly
fights) the failure: `start_owner_stable!/1` retries past `:already_shared`, and
`drain_live_kinds/0` flushes in-flight Kind queries before the owner stops. But the
residual class survives:

- A non-async test finishes; its shared-owner `Agent`'s `stop_owner` `on_exit` runs and
  the owner terminates.
- **`DBConnection.Ownership.Manager` reverts the pool to `:manual`** the instant that
  owner's `:DOWN` lands ("a connection's mode reverts to :manual if its owner
  terminates" — verbatim in every #1037 warning).
- Any process running a Repo query **not in the next test's `$callers` chain** —
  a globally-supervised `Kind.Server` in `init/1` (`kind/server.ex:110` →
  `Kind.Snapshot.fetch_snapshot`), `EventLog.append` from `Kind.Runtime`, or
  `Workspace.Loader.load_all/0` — raises `DBConnection.OwnershipError`.

The #1037 log is saturated with exactly this (`Ezagent.Kind.StateRebuilder.snapshot_exists?:
snapshot lookup raised … OwnershipError`, `Ezagent.AgentBridge.Channel: failed to ensure
Agent Kind … OwnershipError`, `EventLog.append failed … :proc_lib`). Most are swallowed
as log noise; two of them land **inside a hard assertion** — that's PluginIsolation.

### 1.2 `PluginIsolationWorkspaceTest` — the 2 hard failures

File: `apps/ezagent_domain_workspace/test/integration/plugin_isolation_workspace_test.exs`.
Loader: `apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex`.

Actual #1037 assertion:

```
apps/ezagent_domain_workspace/test/integration/plugin_isolation_workspace_test.exs:118
load_all_until_present: workspace "invariant-183778" never appeared in Loader results with children
```

**Which path fires (disambiguated against the #1037 log):**
`gh run view 28272814108 --log | grep -c "DB unavailable"` → **0**. So the `load_all/0`
rescue (path a, below) did **not** fire in #1037. The failure is **path (b)** — empty
children from the `:instantiate` dispatch.

Mechanism, step by step (path b — the one that fired):

1. The test calls `Workspace.create(name, %{members: [probe_uri]})` (persists a row in
   the shared DB on the test's checked-out connection) then drives
   `Ezagent.Workspace.Loader.load_all/0`.
2. `load_all/0` does `Workspace.Store.list_all() |> Enum.map(&load_one/1)`. `list_all/0`
   runs in the test's `$callers` chain and **succeeds** — the workspace row is found.
3. `load_one/1` → `instantiate_via_dispatch/1` dispatches `:instantiate` to the
   workspace's own Kind via `Router.dispatch` (`loader.ex:441+`). That Kind is
   **globally supervised** — its DB reads/child-spawns run **outside the test's
   `$callers`**. When the shared pool has reverted to `:manual` (a prior workspace-app
   non-async test's owner terminated), those reads raise `OwnershipError`, the dispatch
   yields no live children → `{name, []}` — **present but children empty**.
4. The retry helper `load_all_until_present/1` (50× / ~1 s, added in #734) requires the
   workspace present **with non-empty children**. Since the revert persists until a *new*
   shared owner is installed (which won't happen mid-test), all 50 retries see the same
   empty children → `flunk("never appeared … with children")`.

This is why "retry the read" did not fix it (contributing
`feedback_question_the_problem_when_fix_keeps_failing`): the read is correct; the
**connection the dispatched Kind needs is gone**. The fix must `Sandbox.allow/3` the
spawned Kind onto the test owner (or hold shared mode stably), not bump retry count.

**Path (a) — the dormant `OwnershipError`-as-`[]` mask** (`loader.ex:406-416`):

```elixir
rescue
  e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
    Logger.warning("…DB unavailable at boot…"); []
```

If `list_all/0` itself ever raises on a reverted pool, this catch returns `[]` and the
workspace is **absent entirely**. It did NOT fire in #1037 (grep = 0) but it is a latent
trap: it would convert a broken connection into a silent empty result with a misleading
"never appeared" message. Unmask it in `:test` defensively (Fix 1 companion).

### 1.3 `FsResolverTest` — global-singleton kill/restart races

File: `apps/ezagent_core/test/ezagent/resource/fs_resolver_test.exs` (`async: false`).

`Ezagent.Resource.FsResolver.Registry` owns a **`:protected` ETS table**
(`:ezagent_resource_fs_types`) as a supervised singleton. Several tests deliberately:

- `Process.exit(Process.whereis(Registry), :kill)` then `wait_for_restart` (lines 282, 621), and
- `Supervisor.terminate_child(EzagentCore.Supervisor, Registry)` while the table is gone (line 642),
  asserting `resolve/2` **raises** while down.

`async: false` serialises this suite against *other `async: false`* suites in
`ezagent_core`, but `ezagent_core` also runs many `async: true` suites under
`max_cases: 8`. Any concurrent `async: true` test that calls `FsResolver.resolve/…`
during the kill→restart window hits a transient `:none` or the deliberate
"RAISES when down" path — observed as intermittent reds depending on seed/scheduling.
Secondary: the boot init-replay of plugin `resource_types/0` runs on every Registry
restart (the warnings `skipped … {:duplicate_backend, "uploads"}` /
`throw on init-replay: :boom_from_plugin` in #1037 are these tests' fixtures), so a
restart triggered by one test re-runs replay observable to another.

### 1.4 `DefaultSessionTemplateSeedTest` — boot-seeded rows + shared-mode revert

File: `apps/ezagent_domain_session/test/integration/default_session_template_seed_test.exs`
(`async: false`).

It asserts on `KindSnapshot.list_in_workspace("workspace://system")` — rows written by
`seed_default_session_template/0` **at boot, outside any per-test sandbox** (the moduledoc
says so). Two race surfaces: (a) the boot-seed write vs the first test owner's checkout
(mitigated by the in-`setup` re-seed, but the re-seed itself needs a live owner), and
(b) `create_session(…template: "default")` spawns globally-supervised Session/Agent
Kinds that read the DB outside `$callers` — same OwnershipError class as §1.1 once the
pool has reverted. The `team-alpha` / `system` workspaces are also touched by other
suites in the shared DB, so list reads can see foreign rows.

### 1.5 `AnonUserGCTest` (#108's partner) — sweep against shared rows

File: `apps/ezagent_domain_socialware/test/ezagent/socialware/anon_user_gc_test.exs`
(`async: false`). `GC.sweep/1` queries-and-**deletes** anon-user rows by TTL. In the
shared DB other socialware suites create anon users; a sweep can see/delete foreign rows
(or its own count assertion can be off by foreign inserts), and the spawned Kinds carry
the same shared-mode-revert exposure. Lower frequency than PluginIsolation but the same
two root classes.

### 1.6 The `ON CONFLICT` / `workspaces` migration-state error

This is the same shared-DB class viewed from a writer: a globally-supervised boot writer
(e.g. the `workspace://system` / default-template seed, or a Kind snapshot upsert)
performs an `INSERT … ON CONFLICT` against the **shared** `workspaces` /
`kind_snapshots` table while a concurrent test owner's checkout governs the same rows. It
is **not** "a DB reset mid-run" — the umbrella never drops the DB mid-run. It is concurrent
upserts to shared rows plus the reverted-pool ownership error surfacing on the write path.
(Confirm the exact text on the next occurrence with `--log-failed`; the dominant, reliably
reproducible failure is PluginIsolation per §1.2.)

### 1.7 Independent latent bug — `required_caps/0` not implemented

`Ezagent.Behavior` lists `@callback required_caps() :: …` (`behavior.ex:340`) and it is
**not** in `@optional_callbacks` (`behavior.ex:559`). The test fixture `ProbeBehavior`
(`plugin_isolation_workspace_test.exs:46`) omits it — #1037 logs
`warning: function required_caps/0 required by behaviour Ezagent.Behavior is not
implemented (in module …ProbeBehavior)`. Today a missing required callback is only a
compile warning in Elixir, so it does **not** by itself fail the run — but it is genuine
contract drift and should be fixed alongside (add `def required_caps, do: %{}`), so the
fixture matches the production contract and the warning stops masking signal.

---

## 2. Is it CI-environment-specific?

Partly — CI **amplifies** a real defect; it is not a pure CI artifact.

| Factor | Local (single app) | CI (full umbrella) | Effect |
|---|---|---|---|
| DB partition | dev runs one app, often a private DB | **no `MIX_TEST_PARTITION`** → single shared `ezagent_pg_compat_test` | cross-app rows + seeds visible everywhere |
| Concurrency | quieter; fewer prior owners churning | `max_cases: 8` (8-core runner) | more owner births/deaths → more shared-mode reverts |
| Suite set | `:umbrella_only` cross-tier suites excluded standalone | all suites run (siblings on the path) | the integration suites that spawn global Kinds actually run |
| Boot seeds | may be absent if app booted alone | every app boots its full tree → seeds `workspace://system`, default template, routing | the boot-writer rows the seed tests read are present and contended |
| `uv` / node / esbuild | usually present locally | present in CI (`pnpm install`, node 25) | NOT the flake cause; `py_default` `:uv_not_found` is a benign warning, asset build is green |

The discriminator is **shared-mode revert frequency × shared-DB row contention**, both
maximised by the full-umbrella, unpartitioned, `max_cases: 8` CI invocation. The defect
(masked OwnershipError, global-singleton kills) is real on any machine; CI just hits it
more often.

---

## 3. Reliable LOCAL reproduction

The flake **requires the full umbrella** (the standalone single-app run produces a
*different*, cross-tier `*.app` missing-dep failure set — those are `:umbrella_only`
suites, not the flake). Faithful repro = CI's exact invocation against a **private
partitioned DB** (never the shared dev DB):

```bash
# from a worktree off origin/main
export MIX_ENV=test
export MIX_TEST_PARTITION=$USER        # → private DB ezagent_pg_compat_test$USER
export POSTGRES_PORT=55432             # local pg-compat container (CI uses 5432)

mix deps.get
mix compile
mix ecto.create --quiet && mix ecto.migrate --quiet

# CI's exact ExUnit invocation — full umbrella, fixed seed, 8 concurrent cases:
mix test --seed 979933 --max-cases 8
```

- **Use the seed from a red CI run** (#1037 = `979933`). A fixed seed makes the
  scheduling deterministic enough to surface the same ordering; sweep a few seeds
  (`for s in 1 42 979933 123456; do mix test --seed $s --max-cases 8; done`) to raise
  the hit rate, since the revert depends on owner-teardown timing.
- **Always set `MIX_TEST_PARTITION`** — this is the task's isolation requirement: it
  gives you `ezagent_pg_compat_test$USER`, a DB nobody else touches, so you never disturb
  the shared dev DB.
- To narrow onto PluginIsolation specifically once you have a red, re-run just that app
  in the umbrella context isn't faithful (it drops `:umbrella_only`); keep it in the full
  run and grep `--log-failed`-style for `never appeared … with children`.

> **Local reproduction status (this run) — important honest caveat:** a single
> full-umbrella run (worktree off `origin/main`, `MIX_TEST_PARTITION=flakerepro`,
> `POSTGRES_PORT=55432`, `mix test --seed 979933 --max-cases 8`) came back **GREEN** —
> the workspace app reported `178 tests, 0 failures` for the **same seed (979933)** that
> failed with 2 failures on CI. This does NOT disprove the diagnosis; it **confirms the
> flake is a timing race, not seed-determined**: the identical seed is red on the
> ubuntu-latest runner (more owner-teardown churn under `max_cases:8`, no DB partition)
> and green on this macOS box. The diagnosis rests on **primary CI evidence** (#1037
> `--log-failed`: 2 PluginIsolation failures + the saturation of `OwnershipError`
> warnings) plus the code mechanism — not on a local red. To raise local hit-rate, run
> the seed sweep below repeatedly; a single green local run is NOT proof a branch is CI-safe.
> (The earlier standalone single-app run's 14 failures were the cross-tier `*.app`
> missing-dep class — a DIFFERENT failure from the flake — and are not cited as repro
> evidence.) <!-- §3-RESULT -->

---

## 4. The fix direction — what makes them DETERMINISTICALLY green

Ordered by leverage. None of these is "retry / bump timeout" (that class already failed —
see #734).

### Fix 1 (highest leverage) — allow spawned Kinds onto the owner + stabilise shared mode

1. **Allow the Loader's dispatched/spawned Kinds onto the test's sandbox owner** (the path
   that fired in #1037, §1.2). `instantiate_via_dispatch/1` spawns globally-supervised
   Kinds whose DB reads run outside the test's `$callers`. The test must `Sandbox.allow/3`
   each spawned Kind onto its owner (or run the Loader so the spawned Kinds inherit via a
   stable shared mode), so the `:instantiate` dispatch never queries on a reverted/foreign
   connection. The seed tests (§1.4) need the same for their spawned Session/Agent Kinds.

2. **Defensive: `Loader.load_all/0` must not swallow `OwnershipError` into `[]` in `:test`.**
   In production the catch is defensible (a boot-time DB-unavailable shouldn't crash the
   umbrella). In `:test` it converts a *broken connection* into a *silent empty result*
   with a misleading "never appeared" message. Gate the rescue out of `:test` (let it
   raise so the real cause is visible). It did not fire in #1037, but it is a latent trap.

3. **Make `EzagentCore.DataCase` re-establish shared mode so it can't revert mid-suite.**
   `start_owner_stable!` already retries *into* shared mode; the residual gap is that the
   share is *lost* when a prior owner dies. Hold the share for the whole test (the
   harness already notes the cold-restart tests block in `wait_until` across the window —
   generalise that: ensure each non-async test's owner is the *current* shared owner at
   the moment its global Kinds query, e.g. re-assert `mode({:shared, owner})` if a
   `:DOWN` reverted it, or `Sandbox.allow/3` the live Kinds onto *this* owner at setup —
   `allow_live_kinds/1` already does this for Kinds alive at setup; extend to Kinds the
   test spawns).

Together (allow spawned Kinds + stable shared mode + unmask the dormant rescue) these
remove the engine behind §1.2, §1.4, §1.5 and most §1.6.

### Fix 2 — per-suite isolation of the killed/mutated singletons

- **FsResolver `Registry`:** the kill/restart/terminate tests should run against a
  **dedicated, test-owned Registry instance** (start a private named Registry + ETS table
  in `setup`, point `resolve/2` at it for the suite), not the shared supervised singleton
  that concurrent `async: true` tests in the same app depend on. Alternatively tag the
  whole `ezagent_core` resolver-kill subset `async: false` AND ensure no `async: true`
  test in the app calls `FsResolver.resolve` (audit). The clean fix is a private instance.
- **SpawnRegistry / scheme registry:** `register("probe", …)` mutates the global ETS set.
  It is idempotent so collisions are benign, but the test should `on_exit` unregister the
  `probe` scheme so a later suite in the same BEAM never sees a stale scheme→spawn binding.

### Fix 3 — reduce shared-DB cross-talk

- Default a **partition in the precommit/CI path** is the wrong lever (one DB per app
  would break cross-tier suites that intentionally share rows). Instead, the seed tests
  should **scope their assertions to rows they wrote** (already done for `team-alpha`
  via unique workspace names; extend the `workspace://system` boot-seed assertions to
  tolerate foreign rows / assert presence-not-exclusivity), and `AnonUserGC.sweep`
  assertions should filter to user UUIDs the test created rather than asserting global
  counts.

### Fix 4 — the latent contract drift (deterministic)

Add `def required_caps, do: %{}` (and `def cap_subjects`/`required_caps` parity per the
§"keys(required_caps) ∪ cap_exempt_actions == actions" invariant) to `ProbeBehavior` so
the fixture matches the live `Ezagent.Behavior` contract and the compile warning clears.

**check_invariants gate:** these are test-isolation fixes; none touches an architecture
invariant. After the fix, run `mix ezagent.check_invariants` (CI's second step) to
confirm no path-allowlist regression.

---

## 5. Pre-push gate — stop pushing red branches

CI runs (from `.github/workflows/ci.yml`): `mix deps.get` → `pnpm install` (assets, so
esbuild can resolve react/zod during `mix compile`) → `mix ecto.create && mix ecto.migrate`
→ **`mix precommit`** (`compile --warnings-as-errors --force` + `deps.unlock --unused` +
`format` + `test`) → **`mix ezagent.check_invariants`**. The `precommit` `test` step runs
ExUnit per app with `--max-cases 8` on an 8-core runner and **no DB partition**.

The gap: there is no single local command that mirrors this against a private DB, so devs
run `mix test` in one app (which excludes `:umbrella_only` and never reverts shared mode
as hard) and push green-looking branches that go red on CI.

**Recommended: add a `ci.local` alias** (root `mix.exs` `aliases/0`) that runs the CI
recipe end-to-end against a partitioned DB:

```elixir
# mix.exs aliases/0
"ci.local": [
  "deps.unlock --check-unused",
  "deps.get",
  "ecto.drop --quiet",
  "ecto.create --quiet",
  "ecto.migrate --quiet",
  "cmd --cd apps/ezagent_web/assets pnpm install --no-frozen-lockfile",
  "cmd --cd apps/ezagent_plugin_world/assets pnpm install --no-frozen-lockfile",
  "cmd --cd apps/ezagent_plugin_hello/assets pnpm install --no-frozen-lockfile",
  "precommit",
  "ezagent.check_invariants"
]
```

run as:

```bash
MIX_ENV=test MIX_TEST_PARTITION=$USER mix ci.local
```

- `MIX_TEST_PARTITION=$USER` → private DB `ezagent_pg_compat_test$USER`; the dev never
  touches the shared dev DB (task constraint) and two devs can run concurrently.
- To match CI's concurrency exactly, also `export ELIXIR_ASSERT_TIMEOUT=…` is unnecessary;
  set the test args via a `precommit` that passes `--max-cases 8` (CI gets 8 from the
  runner's core count; pin it locally so a dev's higher core count doesn't *hide* the
  flake): change the `precommit` alias `"test"` → `"test --max-cases 8"`, or add a
  separate `"test.ci": "test --max-cases 8 --max-failures 0"`.
- **Flake-hunt mode** (run before merging anything that touches Kind/Workspace/Loader):
  `for s in 1 42 979933 123456 314159; do MIX_TEST_PARTITION=$USER mix test --seed $s --max-cases 8 || break; done`

**Until Fix 1-3 land**, the gate's job is to *catch* the flake locally (so admin-merge is
a conscious decision on a verified-clean branch per contributing P5), not to hide it.
After Fix 1-3 land, the gate is the durable guard that keeps `main` green.

---

## Appendix — file/line index

- CI workflow: `.github/workflows/ci.yml` (`mix precommit` + `mix ezagent.check_invariants`,
  pg service on 5432, no `MIX_TEST_PARTITION`).
- `precommit` alias: `mix.exs:125-130` (`compile --warnings-as-errors --force`,
  `deps.unlock --unused`, `format`, `test` — no seed pin, no `--max-cases`).
- Test DB config: `config/test.exs:8-40` (PostgreSQL, `database:
  "ezagent_pg_compat_test#{MIX_TEST_PARTITION}"`, `pool: Ecto.Adapters.SQL.Sandbox`,
  `pool_size: 20`; local default port 55432, CI 5432).
- Shared harness: `apps/ezagent_core/test/support/data_case.ex`
  (`setup_sandbox`, `start_owner_stable!` shared-mode retry, `allow_live_kinds/1`,
  `drain_live_kinds/0` — the prior #52/P6 remediations; the residual revert is what
  still bites).
- Loader OwnershipError mask: `apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex:398-440`
  (`load_all/0` rescue → `[]`; `load_one/1` → `instantiate_via_dispatch/1`).
- PluginIsolation suite: `apps/ezagent_domain_workspace/test/integration/plugin_isolation_workspace_test.exs`
  (`use EzagentCore.DataCase, async: false`; `load_all_until_present/1` retry; `ProbeBehavior`
  missing `required_caps/0`).
- FsResolver suite + singleton: `apps/ezagent_core/test/ezagent/resource/fs_resolver_test.exs`
  (kill/restart/terminate of `Ezagent.Resource.FsResolver.Registry`, `:protected` table
  `:ezagent_resource_fs_types`).
- DefaultSessionTemplate seed suite: `apps/ezagent_domain_session/test/integration/default_session_template_seed_test.exs`
  (`workspace://system` boot-seeded rows read across the sandbox boundary).
- AnonUserGC suite: `apps/ezagent_domain_socialware/test/ezagent/socialware/anon_user_gc_test.exs`
  (`GC.sweep/1` row deletes against the shared DB).
- Behavior contract: `apps/ezagent_core/lib/ezagent/behavior.ex:340` (`required_caps/0`
  `@callback`), `:559` (`@optional_callbacks` — `required_caps` absent → required).
- Prior art / process: contributing P5 (`docs/together/contributing/README.md`),
  task #108 (flake-hardening), pg-only migration return
  (`docs/together/2026-06-22/returns/pg-compat-audit.md`).
- Actual red run analysed: PR #1037, `gh run view 28272814108 --log-failed`
  (2 failures, both `PluginIsolationWorkspaceTest` PHASE 4 INVARIANT tests, seed 979933,
  `max_cases: 8`).
