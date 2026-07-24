# Profile rollback fix report

## Outcome

Fresh TemplateSpawn failures after display-profile persistence now compensate
only the profile row inserted by that spawn attempt. A profile that already
existed for the same canonical Agent URI is preserved.

## Implementation

- `Ezagent.Entity.Profile.ensure_agent_display_name_with_receipt/2` returns
  `:inserted` when the caller owns the insert and `:exists` for both the
  ordinary pre-existing path and a lost concurrent primary-key race.
- The existing `ensure_agent_display_name/2` API remains a compatibility
  wrapper.
- `Profile.rollback_agent_display_name/2` treats `:exists` as a no-op and
  handles `:inserted` with an exact primary-key `delete_all`. Delete counts
  zero and one both succeed, making compensation idempotent.
- TemplateSpawn threads the insertion receipt through its fresh-spawn
  obligations. Only an `:inserted` receipt is added to rollback work.
- A test-build-only hook immediately after profile persistence provides a
  deterministic later-failure boundary.

The new TemplateSpawn regressions verify that this failure leaves no profile,
worker, lineage, workspace-registry entry, flavor attribute, config directory,
credential grant, creation inventory, or ownership edge. The complementary
case seeds a same-URI profile and verifies that the exact struct survives while
all fresh-spawn artifacts are removed.

The Profile coverage also verifies sequential receipt semantics, exact and
idempotent rollback, preservation of a different Agent profile, and concurrent
same-URI calls producing exactly one `:inserted` and one `:exists` receipt.

## Test-driven evidence

Before implementation, the clean isolated partition produced the expected
failures:

```text
$ cd apps/ezagent_domain_identity
$ ... MIX_TEST_PARTITION=profilerollback mix test \
    test/ezagent/entity/profile_test.exs --seed 0
16 tests, 2 failures
```

Both failures were undefined receipt/rollback APIs.

```text
$ ... MIX_TEST_PARTITION=profilerollback mix test --no-start \
    apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs:368 \
    apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs:436 \
    --seed 0
2 tests, 2 failures
```

Both expected the injected post-profile error, but the old flow completed
successfully because it had no such failure boundary or profile receipt.

## Focused verification

The `profilerollback` database was freshly created and migrated through
`EzagentCore.Repo`. Final commands used:

```text
MIX_ENV=test
MIX_TEST_PARTITION=profilerollback
MIX_DEPS_PATH=/home/lenovo/workspace/ezagent/deps
MIX_BUILD_PATH=/home/lenovo/workspace/ezagent/_build
```

```text
$ cd apps/ezagent_domain_identity
$ ... mix test test/ezagent/entity/profile_test.exs \
    test/ezagent/entity/profile_concurrency_test.exs --seed 0
18 tests, 0 failures
exit 0

$ cd ../..
$ ... mix test --no-start \
    apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs \
    --seed 0
21 tests, 0 failures
exit 0

$ mix format --check-formatted <six touched source/test files>
exit 0

$ git diff --check
exit 0
```

One accidental run without the partition variables reached the previously
reused default database and reproduced its stale partial-index migration
behavior in the no-email User test. The same complete Profile suites pass on
the freshly migrated partition above.

Per task direction, the full `mix precommit` gate was not run. Pre-existing
changes to `task-1-report.md` and `task-4-report.md` were left untouched and
excluded from this fix.
