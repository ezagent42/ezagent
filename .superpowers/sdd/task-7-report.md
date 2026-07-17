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
