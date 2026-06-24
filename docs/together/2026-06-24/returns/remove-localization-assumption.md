# remove-localization-assumption Return

Date: 2026-06-24

Integration branch: `remove-localization-assumption`

Base: `origin/main@94ae55a7`

Worktree: `/Users/h2oslabs/Workspace/esr-ng/.worktrees/remove-localization-assumption`

## Summary

Implemented the behavior-preserving workspace locality gate plan in two PR slices, both fast-forward merged into `remove-localization-assumption`.

PR1 adds the core workspace placement facade and owner gate, then routes workspace-bound dispatch, spawn, and session create/repair through that gate. In local-only mode the default resolver keeps current behavior, but the call sites now have an explicit ownership decision point.

PR2 adds the plugin-side contract and a static invariant for plugin workspace locality assumptions. Existing plugin-local assumptions are intentionally exposed through a central allowlist with exact path, line, pattern key, snippet, and reason. The invariant also prints a warning summary for the allowlisted debt and supports `ENFORCE_WORKSPACE_LOCALITY_DEBT=1` to fail while debt remains. Future plugin changes must either enter through owner-gated core APIs or update that registry explicitly.

## Branches And Commits

- Integration: `remove-localization-assumption`
- PR1 branch: `feat/workspace-locality-core-gate`
  - `330b3ff8 feat(core): add workspace placement facade`
  - `943a421c feat(core): add workspace owner gate`
  - `1d2e888d feat(core): gate workspace dispatch and spawn`
  - `a1577634 feat(session): gate session creation by workspace owner`
  - `848c3b79 docs(core): document workspace locality APIs`
- PR2 branch: `feat/workspace-locality-plugin-invariants`
  - `5724a81f docs: add workspace locality plugin contract`
  - `47041cab test(core): guard plugin workspace locality contract`
  - `fda13ade test(core): warn on plugin locality debt`

## Validation

PR1:

- Focused core/session suite: passed.
- `mix ezagent.doc.scan`: passed with `undocumented_public_defs count=391 cap=392`.
- `mix test apps/ezagent_core/test/architecture/doc_coverage_test.exs`: passed, 17 tests.
- `mix precommit`: passed after restarting the local `ezagent-pg-compat-audit-postgres` container and rerunning from clean state.

PR2:

- TDD red check: strict plugin invariant initially reported 38 plugin locality hits; one was a docstring false positive, leaving 37 real current debt entries.
- Focused invariant suite: `mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs` passed, 5 tests.
- Debt warning is visible in focused and full runs: `workspace locality debt: total=37`, grouped as `kind_registry_lookup=17`, `spawn_registry=16`, `genserver_to_pid=4`, `registry_lookup=0`.
- Enforcement check: `ENFORCE_WORKSPACE_LOCALITY_DEBT=1 mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs` fails as intended while the allowlist is non-empty.
- `mix precommit`: passed after the warning commit.

## Notes

- No distributed BEAM routing behavior is introduced in this slice.
- No existing plugin local assumptions are removed in PR2; they are made explicit, centrally reviewed, and printed as warning debt.
- The local resolver currently maps all workspaces to the local BEAM node. A future distributed resolver can replace that boundary without changing the guarded call sites.
- The earlier validation failure was environmental: the local Postgres compatibility container had exited. After restart, the failed files and full precommit passed.

## Suggested Next Step

Open two PRs with target branch `remove-localization-assumption`, one for `feat/workspace-locality-core-gate` and one for `feat/workspace-locality-plugin-invariants`, then have lead review the integration branch as the combined return.
