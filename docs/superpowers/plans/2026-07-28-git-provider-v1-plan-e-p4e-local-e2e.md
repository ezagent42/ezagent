# Git Provider V1 Plan E — Slice P4e: Local End-to-End Acceptance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver design §8 — the local acceptance run that exercises the whole
provider-owned PR loop end to end, twice, plus its eight fault-injection cases.
This is the slice that decides whether the phrase "Git Provider Plan E 本地
provider-owned PR loop 当前切片完成" (§11) may be spoken.

**Depends on:** P4c (stage runner) and P4d (observation).

**Owner app:** `apps/ezagent_plugin_git_workflow` (tests only, plus test
support). This slice should add **no production code**. If it needs to, that is
a finding about an earlier slice — report it rather than patching here.

---

## One design line is stale — read this before wiring the seam

Design §8 lists among the E2E's ingredients:

> 显式 test-authorized execution backend

That was written on 2026-07-25, when §3.1 made production a permanent dead end.
**§3.4 (2026-07-28) lifted that**: `ExecutionSeam`'s `compile_env` default is now
the real `CapBacked` backend, and P4b shipped it with its own adversarial tests.

- [ ] **Use the real backend.** An E2E that swaps in a test-authorized double
      proves the pipeline works *given* authorization; using the real one proves
      the pipeline works *including* authorization — which is the whole point of
      §3.4 and the reason this E2E exists. What stays stubbed is **GitHub**
      (`Req.Test`), never the seam.
- [ ] Note this deviation from §8's literal wording in your report, with the
      §3.4 reference, so the design can be corrected rather than the code
      quietly diverging from it.

Everything else in §8's ingredient list stands: fresh PostgreSQL test partition;
a temporary local bare repository with a real task-worktree provision; `Req.Test`
for GitHub App JWT / installation / Git Data / PR / checks / reviews; and the
real workflow store, CAS, and restart reconciliation.

---

## Task 1 — The harness

**File:** `apps/ezagent_plugin_git_workflow/test/support/plan_e_e2e_case.ex` (new)

Reuse before you write. These already exist and are the sanctioned shapes:

| Need | Existing |
|---|---|
| GitTaskAccess policy fixture | `test/support/git_task_access_fixture.ex` (P4a/P4b) |
| Real Kind dispatch case | `test/support/git_dispatch_case.ex` (P4b) |
| Adapter effect sentinel | `test/support/git_adapter_probe.ex` (P4b) |
| Authority loader swap | `test/test_helper.exs` (P4b) |
| GitHub `Req.Test` stubs | `apps/ezagent_plugin_github/test/support/github_test_helpers.ex` (P3) |
| Local bare repo + real provision | `local_origin!/2` in `change_collector_test.exs` (P2) |

- [ ] A second definition of any of these is a maintenance trap. If one does not
      fit, extend it where it lives rather than forking it — and say so in your
      report.
- [ ] The harness must make a **test worker write one bounded UTF-8 file** into
      the provisioned worktree (§8's main scenario, step 4). That write is the
      only thing standing between "the collector returned []" and a real diff;
      do not simulate it by hand-constructing `FileChange` structs.
- [ ] `Req.Test` stubs must be **stateful enough to be idempotent** — a second
      `create ref` on an existing ref must behave like GitHub does (already
      exists), not blindly succeed. P3's reconciliation tests already model
      this; reuse their stub shapes.

---

## Task 2 — The main scenario, run twice

§8's main scenario in full:

```
accept task → authorize test task → prepare isolated workspace
→ test worker writes one bounded UTF-8 file → collect FileChange
→ mint scoped installation token → create/reconcile commit + branch + PR
→ read PR/checks/reviews → persist normalized facts
```

- [ ] Run the **complete** sequence twice against the same run identity, then
      assert §8's eight properties:

| # | Assertion |
|---|---|
| 1 | exactly one run row |
| 2 | exactly one workspace provision |
| 3 | exactly one deterministic ref |
| 4 | exactly one effective remote commit |
| 5 | exactly one PR |
| 6 | the second pass performs fresh reads but **no duplicate mutation** |
| 7 | token mint count equals the callback count; **no token leaves the plugin** |
| 8 | workflow facts agree with the provider responses |

- [ ] Assertions 3–6 must be made against **what the stub actually received**,
      not against the final state. A test that only inspects the end state
      cannot distinguish "created once" from "created twice, second was a
      no-op" — and those differ exactly where §6.2's crash windows live.
      Count the mutating requests (`POST /git/refs`, `POST /git/commits`,
      `POST /pulls`, `PATCH …`) per pass and assert the second pass's count.
- [ ] Assertion 7 needs a negative half with teeth: grep the persisted rows, the
      emitted telemetry, and the collected log for the stub's token value, and
      assert it appears nowhere. A "we never pass it" claim asserted only by
      reading the source is not a test.
- [ ] `commit_date` is identical across both passes (it comes from
      `run.inserted_at`, which `upsert_facts`' update clause never touches).
      This is the assertion that catches a future "fix" that re-reads the clock.

---

## Task 3 — The eight fault injections

§8 names these; each needs its own named test.

| # | Case | The assertion that gives it teeth |
|---|---|---|
| 1 | authorization unavailable | **zero** side effects before it — no workspace, no file, no HTTP, no Agent. Assert the probes saw nothing, not just that the state is unchanged |
| 2 | provider call before `workspace_ready` | must be impossible; assert the stub received **no** request while the run is below `workspace_ready` |
| 3 | PR POST succeeds but the receipt is lost | re-run reconciles onto the same PR; assert **one** PR and that the second pass issued no second `POST /pulls` |
| 4 | observation response received, then the DB write fails | after recovery, facts are either fully the old tick or fully the new one — never checks from one tick beside reviews from another |
| 5 | branch collision | `:head_ref_conflict`, **no force push** — assert no `PATCH …/git/refs/…` with `force: true` was ever sent |
| 6 | digest conflict | the closed conflict error; the loser makes no mutation |
| 7 | unsupported workspace change | `:unsupported_workspace_change`, no PR, no commit |
| 8 | GitHub 401 / 403 / 422 / 429 / 5xx | each maps to its stable blocker (P4a's `Blocker`), and **no raw response body, header, or token** appears in the persisted error or any log line |

- [ ] Case 3 and case 4 are the ones that justify this slice. Both are
      "the world crashed between an effect and its record" — the class §6.2
      exists for. Neither can be tested by a happy path, and both are easy to
      write in a way that passes without exercising the window. Make the failure
      injection precise (fail the specific call, not the whole tick) and assert
      what happened on the **retry**, not just that no exception escaped.
- [ ] Case 8's leak half applies to all five statuses, not just one.

---

## Task 4 — Restart reconciliation

§8 requires "真实 workflow store/CAS/restart reconciliation". The crash windows
in §6.2 are recovery paths, not just error paths.

- [ ] For each of §6.2's crash windows, resume from the durable state alone —
      re-read the run and facts from Postgres as a fresh process would, with no
      in-memory carry-over — and assert the run converges to the same terminal
      facts as an uninterrupted execution.
- [ ] Include the window P3's KNOWN LIMITATION named: the deterministic ref
      exists and still points at base. P4c writes `deterministic_head_ref` to
      facts before the first mutation precisely so this resume can prove the ref
      is its own. Assert the resume **completes** rather than failing with
      `:head_ref_conflict` — and, as the negative half, that a ref at base which
      is **not** in this run's facts is refused.

---

## Gates

```
mix format --check-formatted
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_git_workflow/test
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_domain_git/test
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_github/test
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
MIX_ENV=test mix ezagent.arch.scan
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

- Run mix from the **umbrella root**; Postgres is on **15432**; capture exit codes.
- These tests touch a real filesystem and a real bare repo — clean up in
  `on_exit`, and make the temp paths unique per test so the file can run
  `async: false` without colliding across runs.

## Stop and report

- The scenario needs production code that does not exist (that is an earlier
  slice's gap, not this slice's to patch).
- A fault injection cannot be expressed against the current stubs without
  making the stub lie about how GitHub behaves.
- Any §8 assertion cannot be made to fail when the behaviour it names is broken.

## On finishing

§11 permits exactly this claim and no more:

> Git Provider Plan E 本地 provider-owned PR loop 当前切片完成。

Explicitly **not**: Git Provider E2E 生产闭环完成; production authorization 已接线;
managed Agent canary 已完成; GitHub merge loop 已完成; Kanban/socialware
projection 已完成. Report against that boundary — and note that even with §3.4's
real backend, the run still executes against `Req.Test`, never real GitHub.
