# 2026-07-24 — full-suite E2E sandbox-ownership investigation (AutoserviceTier1SeedTest)

## Summary

`EzagentPluginKb.E2E.AutoserviceTier1SeedTest` was the board-tracked "sole
deterministic full-suite blocker" (`docs/futures/todo.md`, release-gate
carryover item). Root-caused and fixed the underlying mechanism (PR #1567):
a generic Ecto Sandbox shared-mode owner-exit race, not something specific to
this test. The fix (`Ezagent.Persistence.TransientRetry` now retries
`DBConnection.OwnershipError`, not just `ConnectionError`) is well-justified
and low-risk, but **could not be confirmed sufficient by local testing** — see
§4. This note exists so the next person debugging this class of issue (or
re-litigating whether the fix "worked") has the full trail instead of
re-deriving it.

## 1. Root cause

1. `EzagentCore.DataCase.setup_sandbox/1` (`apps/ezagent_core/lib/ezagent_core/data_case.ex:106-111`)
   maps `async: false` tests (this test uses `async: false`, test file line 35)
   to Ecto Sandbox **shared mode** (`start_owner_stable!(not tags[:async])`).
2. Per the pinned Ecto SQL 3.13.5 source (`deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex:140-150,491-506`):
   shared mode is pool-global and exclusive; "if the test process terminates
   while the worker is using the connection, the connection will be taken away
   from the worker, which will error" — a revert to `:manual` checks in *all*
   existing connections, umbrella-wide.
3. `Ezagent.Kind.spawn/3` → `DynamicSupervisor.start_child(sup, {Kind.Server, ...})`
   (`apps/ezagent_core/lib/ezagent/kind.ex:400-402`) has no `$callers`
   propagation anywhere in `kind.ex` / `kind/server.ex` / `spawn_registry.ex` —
   a freshly-spawned Kind has no route to a DB connection except shared mode.
4. **Live reproduction** (`MIX_ENV=test mix ci.shard.e2e`, this branch's base,
   seed 515225): a `Kind.Server` `handle_info` → `Kind.Snapshot.save_now/4` →
   `Ecto.Repo.Schema.do_insert` chain hit `%DBConnection.ConnectionError{
   message: "owner #PID<> exited ... Client #PID<> is still using a connection
   from owner"}` at exactly `kind/server.ex:1083` (`persist_handle_info_mutation`)
   / `:1030` (`handle_info`) — the function `docs/futures/todo.md:1688` names.
   Caught by the existing `rescue`/`catch :exit` there and logged (this
   particular occurrence was benign: `ezagent_core`'s suite still reported 0
   failures that run) — but it proves the mechanism is real and current.

**Why this specific test is exposed:** `Kind.Server.handle_info/2` always
applies the in-memory slice update regardless of persist success
(`server.ex:1032`), so reads of *live* Kind state are immune. What breaks is
`Ezagent.AutoService.Tier1Seed.seed/1` (`scripts/autoservice_tier1_seed.exs`):
a chain of ~10 *sequential*, *synchronous* Repo-touching steps, several
wrapped in local `rescue e -> {:error, ...}` clauses. Any one step hitting the
race silently becomes `{:error, reason}` → `wire_autoservice_agent` returns
`{:blocked, reason}` → the test's first assertion
(`autoservice_tier1_seed_test.exs:78`, `autoservice_agent_status == :created`)
fails. A long sequential chain has cumulatively higher hit probability than
any single isolated op elsewhere, which is why this test is disproportionately
exposed even though the race itself is generic (item 4 fired in an unrelated
suite).

## 2. Why the existing P6/#1339 drain infra doesn't cover this

`data_case.ex`'s `drain_to_quiescence/0` (teardown-time, `on_exit`) only
guards registered `Task.Supervisor`s (`DeliverySupervisor`, `CapGrantSupervisor`,
external_mirror's two). Two structural gaps: (a) it's a point-in-time poll —
it cannot wait for a message that hasn't been sent yet (e.g. a PubSub-mediated
`:slice_changed` hop between Kinds); (b) more importantly, it runs *after* the
test body's own assertions already ran, so even a perfect drain only protects
the *next* test from connection theft, not *this* test's in-body assertions.

Prior art checked, neither targets this residual:
- PR #948 (merged 2026-06-24) — a different shared-mode owner-exit race
  (umbrella-wide, AuditCase-related).
- PR #1338→#1339 (merged 2026-07-11) — added the Task.Supervisor drain
  infra `data_case.ex` currently has. Its own PR body explicitly scoped this
  residual out: "the OwnershipError lines were largely benign."

## 3. The fix (PR #1567)

`apps/ezagent_core/lib/ezagent/persistence/transient_retry.ex` already
classifies `%DBConnection.ConnectionError{}` as transient (retries, 5
attempts, exponential backoff) — `Kind.Snapshot.save_now/4` already routes
through it, as do `cap/delivery_outbox.ex` and `cap/delivery_outbox/state.ex`.
It did not classify `%DBConnection.OwnershipError{}` — what a *fully reverted*
(not just mid-query) shared pool raises on the next attempt. Added:

```elixir
defp transient?(%DBConnection.OwnershipError{}), do: true
```

`OwnershipError` is structurally test-only (Sandbox doesn't exist outside
`Mix.env() == :test`) — dead branch in prod, zero prod behavior change.
Deliberately scoped to this one chokepoint rather than restructuring
`data_case.ex`'s shared-owner lifecycle (which would remove the trigger event
entirely but touches every `async: false` test in the umbrella — larger blast
radius, filed as a follow-up option, not attempted here).

## 4. Local verification — and its limits (read before trusting "still green")

Five local trials, `MIX_ENV=test mix ci.shard.e2e`, different random seeds,
**did not reproduce `AutoserviceTier1SeedTest` failing even once** — neither
before nor after the fix:

| # | DB | Fix applied? | Result (this test) | Note |
|---|---|---|---|---|
| 1 | shared dev Postgres (55432) | no | pass | single-file run |
| 2 | shared dev Postgres | no | pass | seed 980584 |
| 3 | shared dev Postgres | no | pass | seed 515225 — caught the race live elsewhere (§1.4) |
| 4 | shared dev Postgres | **yes** | pass | seed 563371 |
| 5 | fresh ephemeral cluster (own `initdb`, port 55440, torn down after) | **yes** | pass | seed 574421 |

Trial 5 specifically ruled out "stale shared-DB state changes the seed's
idempotent-skip branches" as the reason local repro fails: it used a
genuinely fresh, isolated Postgres cluster stood up with the same
`initdb`/`pg_ctl` mechanism `.github/workflows/ci.yml`'s `full-suite` job
uses (its own port, own data dir, discarded after). Still green.

As a control, `EzagentPluginKb.E2E.SocialwareP10CodexGateTest` (an unrelated
authz test — "unauthorized" on `author_socialware_template`) failed 4/4 across
both DB conditions in the same runs — proving this local environment *can*
surface real, consistent reds; it just doesn't surface this specific one.
That test is out of scope here and untouched; flagged so a future session
doesn't conflate it with the sandbox-ownership issue.

**What could explain the local/CI gap** (none of these are confirmable from a
dev sandbox — listed so a future investigator doesn't have to re-derive them):

- CI's `full-suite` runs on **self-hosted macOS ARM64**; `ci.yml`'s own
  comments explicitly flag Darwin as deliberately chosen ("the green-reliable
  OS for the concurrent suite" — see the file's header comment and #108) —
  implying Linux BEAM scheduling behaves differently under this suite's
  concurrency, not necessarily "more reliably."
- Scheduler/core-count differences: the `gate` job pins `SCHEDULERS: "8"` for
  a documented contention reason (see its own comment block); `full-suite`
  doesn't override it, so it inherits the runner's default — which may not
  match this dev box's core count, changing the actual race window.
- The self-hosted runner's load/contention profile at CI time is unknown from
  here and may differ from an idle local dev box.

**Also structurally unreachable from a PR:** `full-suite` (all shards,
including `e2e`) has `if: github.event_name != 'pull_request'` — it only runs
on `push: branches: [main]` or the nightly `schedule` cron. There is no
`workflow_dispatch`. A PR's checks will only ever exercise the cheap `gate`
job for this class of test. The only way to get a real signal is a push to
`main` (or waiting for the nightly cron after one).

**Conclusion:** the fix is correct and well-justified by a confirmed,
currently-firing mechanism, and causes no local regressions (`mix ci.fast`
675/676, the 1 red independently confirmed to be unrelated shared-dev-DB
migration contamination from a different concurrent worktree — see PR #1567's
description). But do not treat "still green in five local trials, two of them
DB-fresh" as proof the fix is *sufficient* to flip CI's `full-suite (e2e)`
shard green — that has never been reproduced outside CI in the first place, so
there's nothing local to falsify. Verify against a real CI run before closing
out the release-gate board item.
