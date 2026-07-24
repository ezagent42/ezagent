# Second final-fix report

Date: 2026-07-24
Branch: `fix/agent-display-name-profile`

## Outcome

The four Important re-review blockers are fixed with focused RED/GREEN
regressions:

1. A failed fresh spawn now rolls back only the lineage row and
   `spawned_by` edge inserted by that attempt. An exact pre-existing lineage
   fact and edge survive the failed spawn.
2. A concurrent `derivation_edges` unique race is contained by an Ecto
   savepoint, so the outer AgentLineage transaction can query and accept the
   winning immutable edge instead of failing with PostgreSQL `25P02`.
3. The agent display-name unique index is agent-URI scoped throughout the
   fresh migration chain and safe downgrade paths. A new forward migration
   repairs databases that already applied the original broad `email IS NULL`
   index.
4. Display-name validation and numeric-suffix truncation use Unicode
   codepoints, matching PostgreSQL `varchar(255)` behavior for decomposed
   Unicode.

## Commits

- `89f1b966a` — `fix(agent): preserve pre-existing spawn lineage on rollback`
- `278893ed6` — `fix(core): recover provenance races with a savepoint`
- `c76ca1a4d` — `fix(core): repair agent display-name index migrations`
- `9e0049470` — `fix(identity): enforce profile bounds by codepoint`
- `79a689e97` — `fix(agent): align lineage status fallback`

## RED/GREEN evidence

### 1. Exact pre-existing lineage preservation

Focused test:

```text
MIX_ENV=test MIX_TEST_PARTITION=secondfinalfix \
  mix test \
  apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs:369 \
  --trace
```

RED: `1 test, 1 failure`; after the forced profile failure,
`AgentLineage.lookup/1` returned `:error` instead of the pre-existing owner.

GREEN: the corrected location (`:368`) returned `1 test, 0 failures`. The
test also verifies that the pre-existing durable `spawned_by` edge remains
while the failed fresh worker is terminated.

### 2. Derivation-edge race recovery

Focused test:

```text
cd apps/ezagent_core
MIX_ENV=test MIX_TEST_PARTITION=secondfinalfix \
  mix test test/ezagent/agent_lineage_concurrency_test.exs --trace
```

The test uses two non-sandboxed database owners/connections and a telemetry
barrier that makes both initial edge lookups complete before either insert.

RED: one recorder returned `:ok`; the other raised `Postgrex.Error` with
`pg_code: "25P02"` (`in_failed_sql_transaction`).

GREEN after `Repo.insert(mode: :savepoint)`: `1 test, 0 failures`. The
concurrency test plus the adjacent DerivationEdges suite returned
`8 tests, 0 failures`.

### 3. Migration chain and applied-database repair

Focused test:

```text
cd apps/ezagent_core
MIX_ENV=test MIX_TEST_PARTITION=secondfinalfix \
  mix test test/ezagent/profile_display_name_migration_test.exs --trace
```

The test creates and drops a temporary real PostgreSQL database. It creates
the baseline `entity_profiles` table, seeds two same-workspace/no-email Users
with the same display name, and then migrates `000 -> 010 -> 020`.

RED: migration `20260724000000` failed with PostgreSQL `23505` while creating
the broad `email IS NULL` unique index.

GREEN: `1 test, 0 failures`. The test proves:

- the duplicate no-email Users migrate successfully;
- a duplicate Agent display name in the same workspace is rejected;
- the live predicate contains `/agent/` and not `email IS NULL`;
- both `010` and `020` down paths retain the safe agent-only predicate; and
- `020` repairs a manually recreated legacy broad index, after which a second
  no-email User with the same name can be inserted.

### 4. Unicode codepoint bounds

Focused RED:

```text
cd apps/ezagent_domain_identity
MIX_ENV=test MIX_TEST_PARTITION=secondfinalfix \
  mix test \
  test/ezagent/entity/profile_test.exs:75 \
  test/ezagent/entity/profile_test.exs:89 \
  --trace
```

RED: `2 tests, 2 failures`; both paths raised PostgreSQL `22001`
(`string_data_right_truncation`):

- a 256-codepoint/128-grapheme decomposed name bypassed the changeset length
  check; and
- adding `-2` to a 254-codepoint decomposed base produced 256 codepoints.

GREEN after codepoint validation/truncation: the complete Profile and Profile
concurrency focused suites returned `16 tests, 0 failures`.

## Final focused verification

All verification used `MIX_TEST_PARTITION=secondfinalfix`.

- Core AgentLineage, deterministic race, DerivationEdges, and real migration
  chain: `16 tests, 0 failures`.
- Domain-agent materialization suite from the umbrella root:
  `19 tests, 0 failures`.
- Identity Profile and Profile concurrency suites:
  `16 tests, 0 failures`.
- Post-review compatibility adjustment: AgentLineage suite
  `7 tests, 0 failures`, plus the exact spawn rollback regression
  `1 test, 0 failures`.

An exploratory standalone run of the domain-agent file produced environment
failures because sibling `.app` files and the umbrella config-dir resolver
were unavailable. The supported umbrella-root invocation of the same entire
file passed `19/19`.

## Scope notes

- The pre-existing dirty files `.superpowers/sdd/task-1-report.md` and
  `.superpowers/sdd/task-4-report.md` were not staged or modified by this
  work.
- Per the explicit task instruction, the known-blocking uncapped full
  `mix precommit` was not run. Focused suites, formatting, and diff checks
  were used instead.

## Review

An independent read-only review of the implementation found no Critical or
Important issues and assessed it ready to merge. Its two non-blocking
terminology notes (`upsert` and blanket `forget`) were corrected to describe
the exact-fact and receipt-scoped behavior.
