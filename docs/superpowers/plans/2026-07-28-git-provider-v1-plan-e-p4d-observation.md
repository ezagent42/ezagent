# Git Provider V1 Plan E — Slice P4d: Observation Tick + Snapshots — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the repeatable observation tick that carries a run from `pr_open`
to `observations_current` and keeps it there, persisting one coherent snapshot
per tick. Design §5.3 (durable facts), §5.4 (state machine), §6.3 (observation),
§7.2 (observation is retryable, deadline → `observation_incomplete`).

**Depends on:** P4c (the stage runner reaches `pr_open` and the facts row exists).

**Out of scope:** the §8 acceptance run and its fault injection (P4e).

**Owner app:** `apps/ezagent_plugin_git_workflow`.

---

## What the schema already decided for you

`git_workflow_facts` has, for observations, exactly six columns:

```
checks_summary      :string     reviews_summary      :string
checks_revision     :integer    reviews_revision     :integer
checks_observed_at  :timestamp  reviews_observed_at  :timestamp
```

There are **no detail rows**. Design §5.3 says detail, *if saved*, must use
explicit typed columns/rows rather than an unbounded JSON blob — V1's schema
saves summaries only, and that is the in-scope reading.

- [ ] Do **not** add a table, a column, or a migration to store per-check or
      per-review detail. If you conclude V1 genuinely needs detail rows, stop
      and report — that is a design decision.
- [ ] Do **not** serialize a list of checks into `checks_summary` as JSON. That
      is the unbounded blob §5.3 forbids, wearing a string's clothes.

---

## Task 1 — The summary functions, and the one thing they must never do

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/observation_summary.ex` (new)

Design §6.3's closing line is the whole test surface here:

> 空 checks 或空 reviews 是有效事实，不得伪造成通过或批准。

- [ ] `summarize_checks([Check.t()]) :: String.t()` — bounded, deterministic,
      and **an empty list must produce a summary that cannot be read as
      success**. `"no checks reported"` is a fact; `"0 failed"` and `"passing"`
      are lies that happen to be arithmetically defensible. Choose wording that
      an operator reading the row cannot mistake.
- [ ] `summarize_reviews([Review.t()]) :: String.t()` — same rule for
      `:approved`. An empty review list is "no reviews", never "not blocked"
      and never anything that reads as approval.
- [ ] Deterministic over ordering: the same set of checks in a different order
      produces the same summary. `list_checks` gives no ordering guarantee, and
      an order-dependent summary would churn `checks_revision` on every tick for
      no reason.
- [ ] Bounded length regardless of input size — a repository with 200 checks
      must not write a 200-entry string into a summary column. Aggregate by
      `status`/`conclusion` (Check) and by `state` (Review); the vocabularies
      are closed (`check.ex` `@statuses`/`@conclusions`, `review.ex` `@states`).
- [ ] No author names, no URLs, no check names in the summary — `Review` carries
      `author_label` and `Check` carries `url`/`name`, and none of them belong in
      a durable summary column (§3.2's leak list, and they would also make the
      summary unbounded).

**Tests**

- [ ] **Empty checks**: the summary contains no substring that reads as success.
      Assert against the actual string, and name the test for the claim.
- [ ] **Empty reviews**: same, for approval.
- [ ] All-succeeded, mixed, all-failed, and still-running cases each produce a
      distinct summary — a summary that collapses "1 failed" and "0 failed" into
      the same string is worse than no summary.
- [ ] Order independence: shuffle the input list, assert identical output.
- [ ] Boundedness: 200 checks produce a summary under a stated byte cap.

---

## Task 2 — The tick

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/observation.ex` (new)

`tick/1` performs §6.3's five steps in order, through `ExecutionSeam.invoke/3`
(never a port or adapter directly), and returns. It is not a loop and not a
process.

| Step | Action | Args |
|---|---|---|
| 1 | `:read_change_request` | `%{change_request_id:, repository:}` |
| 2 | `:list_checks` | `%{commit_sha:, repository:}` |
| 3 | `:list_reviews` | `%{change_request_id:, repository:}` |
| 4 | persist all four facts from this tick together | — |
| 5 | CAS to `observations_current` | — |

- [ ] **Step 2's `commit_sha` is the head SHA from step 1's fresh read — not
      the one stored in facts.** Design §6.3 step 2 says so explicitly ("使用
      fresh-read `head_sha`"). Using the stored value observes checks for a
      commit that may no longer be the PR's head, and the resulting snapshot
      would be internally inconsistent while looking perfectly fine.
      Test it: stub the seam so `read_change_request` returns a head SHA that
      differs from the persisted one, and assert `list_checks` was invoked with
      the **fresh** one.
- [ ] **One tick's facts are written together.** `checks_summary`,
      `checks_revision`, `checks_observed_at`, `reviews_summary`,
      `reviews_revision`, `reviews_observed_at` — plus any `change_request_*`
      the fresh read updated — go in a single `Store.update_facts/2` call. Two
      calls would let a crash leave checks from tick N beside reviews from
      tick N+1, a snapshot that never existed.
- [ ] `checks_revision` / `reviews_revision` increment per tick that actually
      observed. Define and document whether a tick that observes an identical
      result still bumps the revision — either is defensible, but the choice
      must be explicit and tested, because `observed_at` alone cannot tell an
      operator whether the provider was re-queried or the write was skipped.
- [ ] **A repeat tick creates no mutation.** `read_change_request`,
      `list_checks`, `list_reviews` are the only actions this module may invoke.
      Test by asserting the seam never receives `:create_change_request` (or any
      other action) across three consecutive ticks — assert the absence.
- [ ] `pr_open → observations_current` and `observations_current →
      observations_current` are both legal edges in P1's `@legal_edges`; the
      self-loop is what makes repeat ticks work. A tick from any other state
      returns a documented error and does nothing.
- [ ] Failures classify through P4a's `Blocker`. Per §7.2, checks/reviews not
      having appeared yet is **retryable and not a provider failure** — it must
      not push the run to `blocked`. Only a caller-supplied deadline produces
      `blocked: observation_incomplete`; this module does not own a clock or a
      timer.

---

## Task 3 — Deadline handling, owned by the caller

- [ ] `tick/2` accepts an explicit deadline (or an attempt count) from the
      caller. When it is exceeded, CAS to `blocked` with
      `observation_incomplete` and persist the code.
- [ ] The module never sleeps, never retries internally, never starts a timer.
      Whoever drives the ticks owns the cadence — the same shape as P4c's
      `advance/1`.
- [ ] Test: a deadline already in the past produces `blocked:
      observation_incomplete` **and no provider call at all** — assert the seam
      saw nothing. A deadline check that fires after querying the provider has
      already paid the cost it was meant to avoid.

---

## Gates

```
mix format --check-formatted
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_git_workflow/test
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_domain_git/test
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
MIX_ENV=test mix ezagent.arch.scan                # cross_file_duplicate_fn_groups cap is 43
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

- Run mix from the **umbrella root**; Postgres is on **15432**.
- Capture exit codes.
- Add new lib modules to `architecture_test.exs`'s `@source_files`.
- Locality ledger: prefer destructuring heads / `Map.fetch!/2` over adding a
  fingerprint. P4b added zero.

## Stop and report

- The observation needs detail storage the schema does not have.
- `list_checks` cannot be invoked with the fresh head SHA through the frozen
  action vocabulary.
- A summary cannot be made both bounded and unambiguous for some real input.

## Handoff to P4e

- State the exact wording chosen for the empty-checks and empty-reviews
  summaries — P4e asserts on them in §8's "空 checks 或空 reviews 是有效事实"
  case.
- State the revision-bump rule you chose.
- Report which of the three observation actions the tick invoked, and in what
  order, so P4e's Req.Test stubs match.
