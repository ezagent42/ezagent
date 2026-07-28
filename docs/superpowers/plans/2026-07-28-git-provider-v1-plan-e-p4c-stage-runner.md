# Git Provider V1 Plan E — Slice P4c: Durable Stage Runner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive a run from `authorized` to `pr_open` — workspace → changes →
provider — with every stage persisting its facts before it advances, and with
the write ordering that lets a resumed run prove a deterministic ref is its own.
Design §5.4 (state machine), §6.1 (first execution), §6.2 (crash/retry),
§7.2 (retry policy).

**Depends on:** P4a (`Store.update_facts/2`, `Blocker`), P4b (a live seam that
actually reaches the adapter).

**Out of scope:** observation ticks and `observations_current` (P4d); the
end-to-end acceptance run and its fault injection (P4e). P4c stops at `pr_open`.

**Owner app:** `apps/ezagent_plugin_git_workflow`, plus one narrow fix in its own
`Store` (Task 1).

---

## Task 1 — Fix the timestamp round-trip FIRST. It blocks §6.1.

This is not cleanup. **The path design §6.1 mandates is broken today**, verified
by running it:

```
CreateChangeRequest.commit_date  requires %DateTime{}
  DateTime      → {:ok, %CreateChangeRequest{}}
  NaiveDateTime → {:error, {:invalid_field, :commit_date}}

Store.row_to_run/1               →  inserted_at: row["inserted_at"]   # passed through raw
git_workflow_runs.inserted_at    →  timestamp without time zone
Postgrex, via raw Repo.query!/2  →  %NaiveDateTime{}
```

Design §6.1 requires the commit date to be `git_workflow_runs.inserted_at`, read
by the workflow from its own run row and passed into `CreateChangeRequest`. With
today's `Store`, that value arrives as a `NaiveDateTime` and construction fails.
The column type is correct (`timestamps(type: :utc_datetime_usec)` stores UTC in
a naive column by design); what is missing is that raw `Repo.query!/2` bypasses
Ecto's load casting, which is what would otherwise hand back a `DateTime`.

- [ ] In `store.ex`, convert on read in **all three** row mappers — `row_to_run/1`,
      `row_to_facts/1`, `row_to_binding/1`. All three have the same defect;
      fixing only the one that blocks you leaves a trap for P4d/P4e.
      `DateTime.from_naive!(naive, "Etc/UTC")` is the conversion; keep `nil`
      as `nil`.
- [ ] Write the test **first** and watch it fail: read a run back and assert
      `inserted_at` is a `%DateTime{}` with `time_zone == "Etc/UTC"`, and that
      `CreateChangeRequest.new/1` accepts it as `commit_date`. Assert the same
      for facts and bindings.
- [ ] Do **not** change the migration or the column type. The stored value is
      already UTC; this is a load-side conversion only, and a migration would
      touch a table other slices depend on.

> Reported by P4a as a pre-existing P1 defect, left unfixed there because P4a had
> no consumer that broke. P4c is that consumer.

---

## Task 2 — `Store.update_facts/2` value validation

P4a shipped key/identity guards only, so `%{deterministic_head_ref: ""}`
persists an empty string that `WorkflowFacts.new/1` would reject — a fact that
cannot be read back into its own struct.

- [ ] Validate values against the same rules `WorkflowFacts.new/1` applies, so
      anything written can be read back. Reject rather than coerce.
- [ ] Test: every optional column rejects its own malformed value (empty string
      for strings, negative for the revision integers), and a rejected write
      leaves the row **unchanged** — assert the row after, not just the return.

---

## Task 3 — The stage runner

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/stage_runner.ex` (new)

A plain module. **No GenServer, no supervision child, no polling loop.**
`advance/1` performs exactly one stage and returns; crash recovery is calling it
again. This keeps every stage independently testable and makes "resume" the same
code path as "first run".

### Stage table — exact contracts

The runner never calls a port or an adapter directly. Every stage goes through
`ExecutionSeam.invoke/3`, which P4b routes to the real Kind dispatch.

| From → To | Action | Args | Returns | Facts written |
|---|---|---|---|---|
| `authorized` → `workspace_ready` | `:provision_workspace` | `%{task_uri:, generation:}` | `%{provision_id:, resolved_base_commit:, cwd:, local_branch_ref:, start_token:, ...}` | `workspace_provision_id`, `expected_base_sha` |
| `workspace_ready` → `changes_ready` | `:collect_workspace_changes` | `%{task_uri:, generation:}` | `{:ok, [FileChange.t()]}` | `change_digest` |
| `changes_ready` → `pr_open` | `:create_change_request` | `%{changes:, repository:, request:}` | `{:ok, %ChangeRequest{}}` | `change_request_id/url/state/head_ref/base_ref`, `head_sha` |

The arg key sets are enforced by the ActionSet's `@allowed_keys`
(`behavior/git_task_access.ex`) — an extra key is rejected before the handler.
Match them exactly.

- [ ] **`expected_base_sha` comes from `resolved_base_commit`**, returned by
      `provision_workspace` (`provisioner.ex` `ready_result/1`). This is
      semantically the right source: the collected changes are relative to that
      checkout, so it is exactly the base the PR must apply to. There is no
      action in the frozen vocabulary that returns a base SHA any other way —
      do not add one.
- [ ] **`start_token` must never be persisted, logged, or put in an error.**
      It arrives in the same return map as the values you do want. Destructure
      the three fields you need; do not store the map.
- [ ] `change_digest`: a deterministic digest over the collected `FileChange`
      list — same changes ⇒ same digest, independent of collection order if the
      collector's order is not guaranteed. Document the exact input to the hash
      in the moduledoc. Nothing computes this today; you are defining it.

### The write ordering that closes P3's provenance gap

`github_adapter.ex:184-194` records a KNOWN LIMITATION: when the deterministic
ref exists but still points at base, the adapter cannot tell its own retry's ref
from a foreign ref planted at the same name, because there is no commit yet to
compare provenance against. It names the fix: "the workflow's own durable facts
(design §5.3) recording which ref belongs to which run."

- [ ] **Write `deterministic_head_ref` to `git_workflow_facts` BEFORE the first
      `:create_change_request` invocation** — not after, not in the same step.
      A run that crashes between the fact-write and the provider call retries
      into "facts say this ref is mine", which is exactly the identity the
      adapter lacks.
- [ ] The ref value is `DeterministicRef.derive(binding.allowed_head_namespace,
      run.id)` — the same function P4b's policy derivation uses for
      `allowed_head_ref`. Assert in a test that the two agree; if they can drift,
      the ActionSet's `validate_requested_head` will reject the request at
      dispatch time and the failure will look like a policy bug.
- [ ] Test the ordering directly: stub the seam so `:create_change_request`
      raises, then assert `deterministic_head_ref` is **already persisted**.
      A test that only checks the happy-path final state cannot distinguish
      "written before" from "written after".

### Per-stage discipline

- [ ] **Facts first, then CAS.** Write the stage's facts, then
      `Store.transition/4`. A crash between them retries: the facts write is
      idempotent (keyed by `run_id`), then the CAS runs. The reverse order would
      leave a run claiming a state whose facts are absent.
- [ ] Every stage re-reads the run fresh (`Store.read_run/1`) rather than
      trusting a passed-in struct — `state_version` must be current for the CAS
      to mean anything.
- [ ] A stage invoked in the wrong state returns a documented error and does
      nothing. Do not "catch up" by running earlier stages implicitly.

---

## Task 4 — Failure handling wired to `Blocker`

- [ ] Every stage failure goes through `Blocker.from_error/1` then
      `Blocker.classify/1`:
      - `:terminal_blocker` → CAS to `blocked`, persist the code in
        `git_workflow_runs.last_error_code`, stop;
      - `:retryable` → leave the state unchanged, persist the code, return a
        retryable result. Bounded retry policy is the caller's; the runner does
        not sleep or loop.
- [ ] `blocked → blocked` is a legal edge (P1's `@legal_edges`), so a second
      blocking failure re-records without an illegal-transition error. `failed`
      and `cancelled` are the only terminal states — the runner never sets them.
- [ ] **`no_changes_collected` stops at `blocked` and creates no PR** (design
      §7.1's 2026-07-26 amendment). Its own named test: an empty worktree runs
      `authorized → workspace_ready → blocked`, and the seam **never** receives
      `:create_change_request`. Assert the non-invocation, not just the state.
- [ ] Error presentation uses `Blocker.present/4`. No raw dispatch term, no
      provider body, no token, no path reaches a persisted column or a log line.

---

## Task 5 — Idempotency

- [ ] **Running the full sequence twice produces one of everything**: one
      provision id, one deterministic ref, one change-request id, and the same
      `head_sha`. Assert against the facts row, and assert the seam saw
      `:create_change_request` exactly once on the second pass — or, if it saw
      it again, that it returned the same `%ChangeRequest{}` (P3's adapter is
      idempotent by design; the runner must not defeat that by varying its
      inputs).
- [ ] `commit_date` is identical across both passes — it comes from
      `run.inserted_at`, which `Store.upsert_facts`' update clause explicitly
      never touches. This is the assertion that catches someone "fixing" the
      timestamp by re-reading the wall clock.
- [ ] Resuming from each intermediate state (`workspace_ready`,
      `changes_ready`) reaches `pr_open` without repeating the earlier stage's
      side effects.

---

## Gates

```
mix format --check-formatted
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_git_workflow/test
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_domain_git/test
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
MIX_ENV=test mix ezagent.arch.scan                # cross_file_duplicate_fn_groups stays 42
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

- Postgres is on **15432**. Run mix from the **umbrella root** — `cd apps/<app>
  && mix test` loads only that app's deps and yields bogus
  `UndefinedFunctionError`s.
- No `MIX_TEST_PARTITION` should be needed; if you hit `undefined_column`,
  report it rather than working around it.
- Add every new lib module to `architecture_test.exs`'s hand-maintained
  `@source_files`, or it escapes all of that file's scans (including the
  `Cap.issue` / `Cap.store` one). Do **not** weaken its two load-bearing
  assertions.
- Locality ledger is exact-match, shape `{path, {fun, arity}, kind, accessor,
  sha}`, no line number. Prefer eliminating a benign dynamic-receiver read
  (`Map.fetch!/2`, destructuring head) over ledgering it — that is the precedent
  set by `00cd01e10` and followed by P4a.

## Standards

- **Every test must be able to fail.** For each: *"if I deleted the thing this
  test is named for, would it go red?"* Two tests here are specifically
  ordering/absence claims (the pre-write in Task 3, the non-invocation in
  Task 4) — those are exactly the kind that pass vacuously if written loosely.
- **No conclusions from truncated output.** Capture exit codes.
- The workflow mints no caps and reads no `ctx.caps` — that stayed in P4b's
  backend. Grep your diff.

## Stop and report

- A stage needs data no frozen action returns (P3's adapter surface and the
  ActionSet vocabulary are both frozen — design §4.3).
- You need a new column, a migration, or a change to `git_workflow_runs`.
- The ordering in Task 3 cannot be tested because the seam cannot be made to
  fail at that point.
- `DeterministicRef.derive/2` and P4b's `allowed_head_ref` disagree.

## Handoff to P4d / P4e

- Report the final `change_digest` definition (hash input, ordering assumption).
- Report which `allowed_actions` the runner actually invoked, so P4b's list can
  be narrowed if it is wider than needed.
- P4d adds `pr_open → observations_current` and the repeatable tick; P4e adds
  §8's full acceptance run and its eight fault-injection cases.
