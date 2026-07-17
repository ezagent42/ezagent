# Task 7 report — recover expired starting rows conservatively

## RED

Command:

`SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`

Observed: 24 tests, 3 failures.

- Expired `:starting` process-death row produced `%{attempted: 0, cleaned: 0}`.
- Stale-claimant race setup likewise produced no recovery candidate.
- Boot did not call the injected wait function for an active start lease.

These were the expected missing-behavior failures; the test suite compiled and existing tests remained green.

## GREEN

Implemented:

- Included expired or nil `start_lease_until` `:starting` rows in the bounded effect query.
- Included active start leases in the existing single bounded boot-deadline query/window, selecting the status-appropriate lease column.
- Added `request_expired_start_cleanup/4`, which under the row lock requires the exact `:starting` status, `state_version`, and `start_claim_token`, rechecks lease expiry, and moves the row to `:cleanup_pending` as `:ambiguous_or_live`.
- Routed recovered starts through the existing `claim_and_clean/3`; no instantiate path was added or retried.

Focused verification after format:

`24 tests, 0 failures`

Full Workspace verification:

`299 tests, 0 failures`

The full suite emitted pre-existing compiler/runtime warnings and sandbox disconnect logs, but exited successfully with zero failures.

## Self-review

- Race safety: a renewed/reclaimed start changes the version/token, so the recovery CAS loses without effects; an active lease also fails the locked expiry recheck.
- Stale worker: after recovery, the old token cannot `mark_started/4` or `fail_start/4`; both return `:invalid_start_transition` after cleanup completes.
- Destructive ordering/fencing: recovered starts reuse canonical cleanup. Cleanup ownership is claimed first; retirement renews the cleanup token before sanctioned retirement; Git verify/remove renews around each destructive effect; final marking validates the same token.
- Canonical path proof remains before the recovery transition, so path-coordinate mismatch fails closed without retirement/removal.
- Boot remains a bounded two-pass one-shot. No loop, instantiate retry, new cleanup implementation, or unrelated handoff changes were introduced.
- `git diff --check` passed. Only Task 7 source/tests are staged; the unrelated untracked handoff is preserved.

## Review follow-up

### RED

Focused command:

`SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`

Observed before the follow-up implementation: 29 tests, 2 failures.

- The deterministic reclaim race expected `%{attempted: 1, cleaned: 0, failed: 0}` but stale recovery won first and cleaned the row because no interleave seam existed.
- The real caller-death test reached recovery but failed closed with `:workspace_path_mismatch`; the existing sidecar fixture deliberately used a hardcoded proof path rather than canonical `Paths.derive/1` coordinates.

### Concurrency and lifecycle orchestration

- Real process death: a spawned caller is granted SQL sandbox access, calls the real `CorePreStart.prepare/1`, signals only after the durable row is `:starting`, then is killed before `complete/2`. Recovery runs after the persisted lease deadline, retires and cleans, and observes no instantiate call.
- Stale snapshot race: the test-only `after_candidate_list` hook runs after the bounded query materializes the old row and before `recover/2`. The hook reclaims start with the original durable start token at the expiry instant, producing a new state version, claim token, and active lease. The stale CAS loses under the row lock and is counted as a benign skip; the new claimant remains authoritative and no retirement/Git removal occurs.
- Cleanup ownership: retirement is paused after `claim_cleanup/2` has installed a cleanup token. Both old-token `mark_started/4` and `fail_start/4` return `:invalid_start_transition`; Git removal has not run. Releasing retirement resumes the canonical fenced cleanup.
- Boot restart: tests start `ReconcilerBoot` as a real child under a fresh supervisor against already-durable starting rows. One test observes expired-start retirement inside the supervised boot process; another blocks the real child in its active-lease wait, advances the injected clock, then observes the second pass clean the row and the temporary child exit normally.
- Nil lease: a direct `start_lease_until: nil` starting row is selected, retired, and cleaned as ambiguous/live.

### GREEN

After formatting, the focused command reported:

`30 tests, 0 failures`

Full Workspace command:

`SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test`

reported:

`305 tests, 0 failures`

The full suite retained its pre-existing compiler/runtime warnings and sandbox disconnect logs but exited successfully. `git diff --check` also passed.

### Follow-up self-review

- The interleave hook is compiled only under `Mix.env() == :test`; production has a no-op private implementation.
- Only expected CAS-loss outcomes (`:sidecar_start_claim_lost`, `:start_lease_active`, `:invalid_cleanup_transition`) become `{:skip, :stale_start_snapshot}`. Canonical path failures, DB errors, retirement failures, and Git failures remain failed recovery attempts.
- Exact state-version/start-token matching and the locked lease recheck remain unchanged.
- No instantiate retry path was introduced, and the canonical cleanup-token fencing remains the sole destructive path.
