# Task 2 report — durable credential-gated agent admission

## Outcome

Implemented the durable candidate admission state machine outside
`create_session/3`.

- Gated roles without a valid credential source are recorded under the session
  working-copy `:agent_admissions` key and returned as non-fatal `deferred`
  results.
- `begin/4` creates one managed provisional agent backed by its durable
  `CreationInventory` attempt ID, without adding a session membership edge.
- `complete/4` performs the authorized credential-status read, reuses the normal
  recipe/cap/join pipeline, sets the cap-checked default source, and records
  `:joined`.
- Authentication, materialization, cancellation, timeout, and source-write
  failures use the durable retirement path and record `:failed`; retry creates a
  new attempt.
- Admission mutators re-read the live declaration/revision, serialize by
  session/role, reject stale attempts, and emit credential-free transition
  telemetry.
- Immediate roles retain their existing materialization path.
- Static architecture coverage proves `create_session/3` does not begin an
  admission or spawn a candidate.

## TDD evidence

Initial focused lifecycle test failed as expected because the gated role was
returned through the legacy missing-credential `skipped` lane:

```text
expected: %{satisfied: ["front-desk"], skipped: [], deferred: ["llm"]}
actual:   gated "llm" present in skipped with :no_credential_source
1 test, 1 failure
```

After implementation and scoped review:

```text
mise exec -- mix test \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_domain_session/test/architecture/session_create_no_agent_spawn_test.exs

39 tests, 0 failures
```

`mix format` was run for all six Task 2 files and `git diff --check` passed.
Full `mix precommit` was intentionally not run per coordinator instruction.

## Scope and concerns

Only the six Task 2 implementation/test files are included in the Task 2
commit. Other agents' concurrent changes and existing report/plan artifacts
were left unstaged.

No known Task 2 correctness concern remains. The focused integration run emits
existing asynchronous deferred-dispatch/teardown log noise, but exits
successfully with all 39 tests passing.

## Important-review hardening — 2026-07-30

Addressed all five Important findings from the post-Task-2 review:

- `:joined` is now durable only after the cap-checked default credential source
  pointer succeeds. A pointer-boundary fault proves failure never exposes
  `:joined`.
- `defer`, `begin`, `clear`, expiry, and gated materialization reconcile rows
  against the live declaration flavor and template revision. Stale active rows
  are retired before replacement; stale terminal rows are cleared.
- Provisional cleanup validates the exact `CreationInventory` tuple and current
  lineage before tombstoning a recipe binding or removing session membership.
- Post-spawn admission-write cleanup and fresh-spawn rollback failures are
  returned as compound errors. The admission writer also converts exits into
  explicit write failures so compensation cannot be bypassed.
- The create-session no-spawn architecture gate now walks the reachable local
  call graph and detects concrete Agent spawn writers, including a fixture whose
  writer is hidden behind innocuously named helpers.

### TDD evidence

The new regressions failed before the hardening with four behavioral failures:
stale active candidates remained live, stale `begin` returned the old joined
row, wrong-attempt cleanup mutated state before failing, and pointer/cleanup
failure ordering exposed the wrong state/error. The strengthened architecture
fixture also caught an initial arity-zero call-graph gap.

An exact admission-write injection then exposed one more recovery hole:
`system_set_working_copy` exited while the session was suspended, bypassing the
cleanup branch. `write_admissions/2` now converts throw/exit failures into the
same explicit error lane; the regression proves both the durable-write failure
and the cleanup lineage mismatch are retained.

### Green verification

```text
mise exec -- mix test \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_domain_session/test/architecture/session_create_no_agent_spawn_test.exs

47 tests, 0 failures
```

The three files also passed independently (`9/9`, `29/29`, and `9/9`).
`mix format` was run on every touched Task 2 source/test file and
`git diff --check` passed. Full `mix precommit` remains intentionally skipped
under the coordinator's focused-suite instruction.

## Stale completion/cancellation reconciliation — 2026-07-30

The follow-up review found that `complete/4` and `cancel/4` detected a stale
active admission through `validate_row/3` but returned immediately, bypassing
the reconciliation path that retires its provisional agent and clears the row.
Both attempt lookups now run through `reconcile_row/3` before selecting the
requested attempt.

Two regressions mutate the declaration while a candidate is `:authenticating`:
the completion case bumps the template revision, while the cancellation case
changes the flavor without changing the revision.

```text
# RED before the fix
2 tests, 2 failures
# Both failures showed the stale :authenticating row still persisted.

# GREEN after routing both lookups through reconciliation
2 tests, 0 failures

mise exec -- mix test \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs

11 tests, 0 failures
```

## Default credential-pointer compensation — 2026-07-30

Admission completion now persists a materializing pointer transaction before it
advances the default credential source: the old source URI and the candidate
source URI. If the joined-row write fails, cancellation/expiry, or stale-row
retirement now conditionally restores the prior source before retiring the
candidate. A restore failure intentionally leaves the candidate live with its
new pointer transaction, rather than creating a pointer to a retired agent.

The regression first completes one candidate to establish a valid old default,
then starts a second candidate and injects a joined-row write failure after its
pointer succeeds. Before the fix it unexpectedly joined and overwrote the
pointer; after the fix it returns the injected error, retires the second
candidate, and resolves the pointer back to the first.

```text
# RED before compensation
expected: {:error, :injected_join_write_failure}
actual:   {:ok, %{status: :joined, ...}}

# GREEN
post-pointer joined-write regression: 1 test, 0 failures
admission suite: 12 tests, 0 failures
```

## Pointer serialization and cleanup reapply — 2026-07-30

Default-source transactions are now serialized globally by
`(owner, workspace, flavor)`, rather than only by `(session, role)`. This
keeps the old-source read, new-source write, conditional restoration, and
candidate retirement in one cross-session critical section. When cleanup fails
after a prior source was restored, the same transaction reapplies the candidate
source, so a still-joined candidate never loses its reusable credential source.

```text
mise exec -- mix test \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs

12 tests, 0 failures
```

## Compensation race regressions — 2026-07-30

Two deterministic test seams now protect the compensation boundary.

- The stale candidate's injected joined-write failure queues a newer completion
  for the same `(owner, workspace, flavor)`. The newer completion is allowed to
  run after stale compensation releases the default-source lock, and must be
  the final pointer and the joined session member.
- A joined-write failure deletes only the candidate's creation-inventory
  winner, making provisional cleanup return `:creation_attempt_not_found` while
  retaining valid candidate lineage. The test proves the old pointer was
  restored first and then reapplied to the still-live, still-joined candidate.

The cleanup assertion is RED against `f681d295^`: that implementation returns
the cleanup failure immediately after restoration, leaving the prior source in
place. It is GREEN with the reapply path. The queued-completion test is a
precise conditional-compensation seam: its forced interleaving proves a stale
compensator cannot overwrite a newer pointer. It also passes with the global
lock wrapper removed because the guarded restore correctly observes the newer
source and declines to overwrite it; the lock adds serialization, not the
underlying last-writer protection.

```text
mise exec -- mix test \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs

14 tests, 0 failures
```
