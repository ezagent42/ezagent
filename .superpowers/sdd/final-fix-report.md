# Agent display-name final fix report

## Status

All Critical, Important, and Minor review findings are addressed in focused
implementation commits. The required focused suites pass. The full
`mix precommit` alias was started after focused verification and capped at 45
seconds per coordinator direction; it completed the forced umbrella compile and
entered the full test phase before the cap terminated it.

## Fixes

### Agent-only profile uniqueness

- Added a forward PostgreSQL migration that replaces the already-applied
  `email IS NULL` partial index with the strict bare Agent URI predicate
  `^entity://[^/:?#]+/agent/[^/?#]+$`.
- Kept the original branch migration immutable and supplied a reversible
  `down/0` path to the prior predicate.
- Made `Profile.ensure_agent_display_name/2` reject non-Agent URIs before any
  profile read or write by using the canonical bare-principal predicate and
  structural Agent type check.
- Added the 255-character application validation and reserved suffix space by
  truncating the requested base. A candidate whose numeric suffix itself cannot
  fit returns a changeset error instead of reaching PostgreSQL.
- Proved multiple no-email Users can share a display name without consuming the
  Agent name.

### Concurrency

- Added two real PostgreSQL concurrency regressions. Every spawned caller owns
  an independent, non-transaction sandbox connection
  (`Sandbox.start_owner!(..., sandbox: false)`) and synchronizes on a barrier.
- Different Agent URIs requesting one base allocate exactly `builder` and
  `builder-2`.
- Concurrent calls for one Agent URI both return the same profile and leave one
  row.

### Fresh-spawn rollback

- Normalized returned errors, exceptions, exits, and throws from profile
  persistence into the fresh-spawn obligation's tagged error path so a raised
  persistence failure cannot bypass rollback or pre-start completion.
- Added insertion-status receipts for `spawned_by` derivation edges and exact
  creation-attempt receipts for creation inventory.
- Rollback now compensates only facts inserted by the failing call: runtime and
  durable lineage, workspace binding, `spawned_by` and `creation_root` edges,
  creation inventory, config directory, credential grant, flavor attribute,
  profile, and worker.
- Legacy and trusted pre-start claims retain their creation inventory receipt;
  the existing completion callback still observes it after worker rollback.
- Added a deterministic 256-character-name regression asserting zero fresh
  worker, lineage, workspace, profile, config, grant, inventory, or ownership
  residue.

### World fixture

- Replaced the hardcoded respawn flavor with the flavor stored from the
  dynamically registered test Template Class.
- Asserted the sandbox respawn data retains that exact registered flavor.

### Documentation

- Corrected the committed design and implementation plan to describe strict
  Agent URI scope, the forward migration, bounded names, independent-connection
  concurrency, exception-safe cleanup, pre-start receipt preservation, and the
  dynamic World flavor.

## TDD evidence

- Profile/concurrency RED: 14 tests, 4 failures covering the old no-email User
  collision, non-Agent acceptance, and PostgreSQL `22001` overlong-name raises.
- Profile/concurrency GREEN: 14 tests, 0 failures.
- Rollback RED 1: all non-ownership artifacts were clean; creation inventory
  remained.
- Rollback RED 2: creation inventory and `creation_root` were clean;
  `spawned_by` remained.
- Rollback GREEN: 1 test, 0 failures with every asserted artifact absent.
- World flavor RED: expected the registered unique flavor, received the
  hardcoded fixture flavor.
- World flavor GREEN: 1 test, 0 failures.

## Final verification

- Forward migration rollback and re-apply: passed.
- `pg_indexes` inspection:
  `WHERE entity_uri ~ '^entity://[^/:?#]+/agent/[^/?#]+$'`.
- `profile_test.exs` + `profile_concurrency_test.exs`:
  14 tests, 0 failures.
- Full `agent_template_spawn_sandbox_materialization_test.exs`:
  18 tests, 0 failures.
- `agent_display_name_test.exs`:
  1 test, 0 failures.
- `agent_lineage_test.exs` + `derivation_edges_test.exs`:
  14 tests, 0 failures.
- `creation_inventory_test.exs`:
  3 tests, 0 failures.
- `git diff --check`: passed before commits.
- `mix precommit`: capped after 45 seconds. Forced compile completed without a
  warnings-as-errors failure; the alias had entered the full test phase. The
  timeout then produced expected forced-shutdown noise from Phoenix Tracker and
  Mix's project stack, so this is not a complete precommit pass.

## Commits

- `b45d122c1 fix(identity): enforce agent-only display names`
- `85d39d6c1 fix(agent): roll back failed display profiles`
- `0140a5cc1 test(world): preserve registered display flavor`
- `ab139975b docs: correct agent display-name guarantees`

## Remaining concerns

- The full umbrella test phase of `mix precommit` did not finish inside the
  coordinator-approved cap. Focused and directly affected core suites are
  green.
- Pre-existing working-tree changes in
  `.superpowers/sdd/task-1-report.md` and
  `.superpowers/sdd/task-4-report.md` were deliberately left untouched and
  uncommitted.
