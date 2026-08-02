# Clean-Slate Per-Grant Durable Revocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task in the current isolated worktree. Use
> superpowers:test-driven-development for every behavioral slice and
> superpowers:verification-before-completion before delivery.

**Goal:** Replace the repository's two compatibility/cutover planes and the
versioned capability protocol with one future-only per-grant revocation
mechanism: every issued artifact has one canonical signed UUID `grant_id`, every
durable carrier validates the same artifact contract, `IdentityCaps.Store` is
the unconditional source of truth, and revocation is an insert-only ledger
decision.

**Architecture:** `Ezagent.Cap.GrantArtifact` is the single canonical boundary
for issued artifacts. Framework issuance mints and signs a UUID grant identity;
durable carriers reject partial or malformed sets; authorization, effective
loading, delivery, authority anchors, and exact revoke consult the same
workspace-scoped ledger. Identity mutations commit the Store row first and only
then project live/snapshot state. Historical migrations remain replayable, but
the current schema drops `users.caps_json` and identity cutover state. A clean
start gate proves empty-database migration, seed, first boot, and cold boot.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, ExUnit, Phoenix umbrella Mix tasks,
`System.cmd/3` for isolated clean-start child processes, Git/GitHub delivery.

## Global Constraints

- Work only in `.worktrees/p2-per-cap-revocation` on
  `feat/p2-per-cap-revocation`; do not merge `main` locally.
- The approved design is
  `docs/superpowers/specs/2026-08-01-per-grant-durable-revocation-clean-slate.md`.
  If code contradicts it, resolve the implementation to the design unless the
  contradiction would expand scope materially.
- There is no capability protocol version, legacy decoding mode, epoch,
  cutover, remint, dual-read, or dual-write. Authority key generations remain
  legitimate key lifecycle data and must not be renamed.
- Unsigned required/request capabilities may have `grant_id: nil`. An issued,
  signed, stored, transmitted, or authorized grant artifact must have a
  lowercase canonical hyphenated UUID.
- `grant_id` is signature-covered but remains excluded from
  `Capability.identity_key/1`, so re-grant creates a distinct artifact for the
  same logical permission.
- All ledger reads fail closed. Never cache absence/non-revocation.
- All capability sets crossing a durable or trust boundary validate
  all-or-nothing; never silently drop one malformed member.
- Preserve the existing self-license authority lock and bootstrap ordering.
  The per-grant work must not add a global crypto/current-authority lock to
  ordinary Store writes.
- Use a unique `MIX_TEST_PARTITION` for focused tests. Keep tests in the owning
  umbrella app and run from the umbrella root.
- Make logical commits after green slices. Optional tested child-phase PRs may
  be opened against and merged into `feat/p2-per-cap-revocation`.
- Final delivery requires pushing the target branch and opening one PR from
  `feat/p2-per-cap-revocation` to `main`. Leave that PR open and unmerged.

---

### Task 1: Replace protocol versions with the canonical GrantArtifact boundary

**Files:**

- Create: `apps/ezagent_core/lib/ezagent/cap/grant_artifact.ex`
- Modify: `apps/ezagent_core/lib/ezagent/capability.ex`
- Modify: `apps/ezagent_core/lib/ezagent/capability/normalize.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/signing.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/grant.ex`
- Test: `apps/ezagent_core/test/ezagent/cap/grant_artifact_test.exs`
- Test: `apps/ezagent_core/test/ezagent/capability_protocol_test.exs`
- Test: `apps/ezagent_core/test/ezagent/cap/signing_test.exs`
- Test: `apps/ezagent_core/test/ezagent/capability_test.exs`

**Interfaces:**

```elixir
defmodule Ezagent.Cap.GrantArtifact do
  @spec from_map(map()) :: {:ok, Capability.t()} | {:error, term()}
  @spec from_term(binary()) :: {:ok, Capability.t()} | {:error, term()}
  @spec validate(Capability.t()) :: {:ok, Capability.t()} | {:error, term()}
  @spec valid_grant_id?(term()) :: boolean()
  @spec validate_set(Enumerable.t(), term()) ::
          {:ok, MapSet.t(Capability.t())}
          | {:error, {:invalid_grant_artifact, term(), non_neg_integer(), term()}}
end
```

`valid_grant_id?/1` must accept only a value for which
`Ecto.UUID.cast(value) == {:ok, value}`. `from_map/1` and `from_term/1` return
tagged errors; they do not raise. `validate/1` requires canonical grant ID,
signature, key ID, grantee, valid term, and valid URI fields. `validate_set/2`
reports the first member index and rejects the full set.

- [ ] Write RED tests for missing/uppercase/unhyphenated/non-UUID grant IDs,
  missing signature/key/grantee, invalid terms/URIs, malformed map/term input,
  deterministic error tuples, and all-or-nothing set validation.
- [ ] Run
  `MIX_ENV=test MIX_TEST_PARTITION=p2ga mix test apps/ezagent_core/test/ezagent/cap/grant_artifact_test.exs`
  and record the expected undefined-module failure.
- [ ] Remove `signing_version` from the capability struct, map/JSON shape,
  normalization, signing bytes, and verification branches. Keep `grant_id` nil
  only for unsigned request/requirement values.
- [ ] Implement `GrantArtifact` and change framework issuance to overwrite any
  caller-provided grant identity with `Ecto.UUID.generate/0` before signing.
- [ ] Add GREEN tests proving two grants of the same logical capability have
  equal `identity_key/1`, unequal `grant_id`, and independently valid signatures.
- [ ] Run the four focused suites plus
  `mix test apps/ezagent_core/test/invariants/cap_signing_invariant_test.exs`.
- [ ] Commit as `refactor(cap): make grant artifacts the only signed protocol`.

### Task 2: Make the ledger and outbox grant identity UUID-native

**Files:**

- Modify: `apps/ezagent_core/lib/ezagent/ecto/cap_revocation.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/revocation_ledger.ex`
- Delete: `apps/ezagent_core/lib/ezagent/ecto/cap_revocation_epoch.ex`
- Delete: `apps/ezagent_core/lib/ezagent/cap/revocation_epoch.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex`
- Modify: `apps/ezagent_core/priv/repo_pg/migrations/20260801000000_create_cap_revocations.exs`
- Delete: `apps/ezagent_core/priv/repo_pg/migrations/20260801000100_create_cap_revocation_epoch.exs`
- Modify: `apps/ezagent_core/priv/repo_pg/migrations/20260801000200_add_grant_id_to_cap_delivery_outbox.exs`
- Test: `apps/ezagent_core/test/ezagent/cap/revocation_ledger_test.exs`
- Delete: `apps/ezagent_core/test/ezagent/cap/revocation_epoch_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/delivery_outbox_hardening_test.exs`
- Modify: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`

**Schema contract:**

```elixir
create table(:cap_revocations, primary_key: false) do
  add :grant_id, :uuid, primary_key: true, null: false
  add :workspace_uri, :text, null: false
  timestamps(updated_at: false, type: :utc_datetime_usec)
end

alter table(:cap_delivery_outbox) do
  add :grant_id, :uuid, null: false
end
```

- [ ] Add RED tests that invalid UUIDs are rejected before query construction,
  ledger marking is idempotent/insert-only, batch reads are workspace scoped,
  and every outbox changeset requires a canonical `grant_id`.
- [ ] Run the focused ledger and outbox suites and record the old text/nullable
  behavior that makes them RED.
- [ ] Convert both Ecto schemas and migrations to `:binary_id`/`:uuid`, delete
  epoch code and make every revocation check unconditional.
- [ ] Preserve `mark/1` idempotence and the existing no-delete invariant; return
  tagged errors from database failures.
- [ ] Run migrations against the task partition, then the focused suites and
  the tenant-table invariant.
- [ ] Commit as `refactor(cap): make revocation ledger unconditional`.

### Task 3: Apply GrantArtifact to every core carrier and authority anchor

**Files:**

- Modify: `apps/ezagent_core/lib/ezagent/cap/authority.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/authorize.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery_outbox/envelope.ex`
- Modify: `apps/ezagent_core/lib/ezagent/event_log.ex`
- Test: `apps/ezagent_core/test/ezagent/cap/authority_checked_verify_test.exs`
- Test: `apps/ezagent_core/test/ezagent/cap/authority_verify_against_current_test.exs`
- Test: `apps/ezagent_core/test/ezagent/cap/authorize_test.exs`
- Test: `apps/ezagent_core/test/ezagent/cap/delivery_outbox_dead_operator_event_test.exs`
- Test: `apps/ezagent_core/test/ezagent/capability_test.exs`

**Anchor load contract:**

```elixir
with {:ok, term} <- safe_binary_to_term(row.anchor),
     {:ok, artifact} <- GrantArtifact.from_term(term),
     :ok <- verify_anchor_row_binding(row, artifact),
     :ok <- Authority.verify_against_current(artifact),
     {:ok, false} <- RevocationLedger.revoked?(artifact) do
  {:ok, artifact}
else
  _ -> {:error, :invalid_authority_anchor}
end
```

- [ ] Add RED tests for anchor bytes that are corrupt, unsafe, not a capability,
  missing/noncanonical grant IDs, row/key/target mismatches, stale authority
  generations, and revoked grant IDs. Each case must fail closed without raising.
- [ ] Add RED carrier tests showing an invalid artifact rejects an entire outbox
  envelope/event payload and a ledger read error denies authorize/delivery.
- [ ] Route anchor decode, Jason capability decode, EventLog restoration,
  envelope decode, enqueue, drain, authorization, and effective-load verification
  through `GrantArtifact`; do not use `%Capability{}` pattern matching as proof.
- [ ] Remove `remint_all_anchors_in_txn/0` and all protocol-remint helpers. Make
  anchor creation use ordinary issuance once.
- [ ] Run all listed tests plus architecture signing/authority tests.
- [ ] Commit as `fix(cap): validate every core grant carrier`.

### Task 4: Validate identity and provider carrier sets atomically

**Files:**

- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/callback_ingress.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity_caps/store_status_decode_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity_caps/store_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/recipe_cap_binding_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/integration/callback_ingress_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`

- [ ] Write RED tests with one valid and one malformed/revoked member for Store,
  RecipeCapBinding, callback attempt restoration, and callback ingress. Assert
  that no subset is returned, stored, or delivered.
- [ ] Run the four owner-app test groups and record the first permissive decode.
- [ ] Replace `Enum.map(&Capability.from_map/1)` and struct-shape checks with
  `GrantArtifact.validate_set/2`, adding target/workspace/issuer predicates via
  options or explicit post-validation checks.
- [ ] Keep serialized receipt/callback metadata outside artifact fields opaque;
  validate only fields that actually serialize a capability.
- [ ] Run the focused suites and provider authority-boundary architecture test.
- [ ] Commit as `fix(cap): close durable artifact carrier boundaries`.

### Task 5: Remove the capability cutover and remint plane completely

**Files:**

- Delete: `apps/ezagent_domain_identity/lib/ezagent/identity/cap_revocation_cutover.ex`
- Delete: `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.cap_revocation.cutover.ex`
- Delete: `apps/ezagent_domain_identity/test/ezagent/identity/cap_revocation_cutover_test.exs`
- Modify: `apps/ezagent_core/lib/ezagent_core/release.ex`
- Modify/delete every remaining source returned by:
  `rg -n 'signing_version|RevocationEpoch|CapRevocationEpoch|cap_revocation_epoch|CapRevocationCutover|cap_revocation_cutover|pre.?epoch|remint' apps config mix.exs`

- [ ] First add the exact forbidden-name scan from Task 9 as a RED invariant so
  removal is machine enforced rather than grep-only cleanup.
- [ ] Delete the epoch migration/module/test, cutover module/Mix/release entry,
  remint helpers, pre-epoch branches, and comments/docs that teach the obsolete
  mechanism.
- [ ] Do not remove or rename authority key version/generation concepts.
- [ ] Run the source invariant and every test directly touched by deletion.
- [ ] Commit as `refactor(cap): delete cutover compatibility plane`.

### Task 6: Drop users.caps_json and the identity cutover plane from runtime

**Files:**

- Delete: `apps/ezagent_domain_identity/lib/ezagent/identity/cutover.ex`
- Delete other modules under: `apps/ezagent_domain_identity/lib/ezagent/identity/cutover/`
- Delete: `apps/ezagent_domain_identity/lib/ezagent/identity_caps/user_store.ex`
- Delete: `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.identity.cutover.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity_caps.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/users.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`
- Modify: `apps/ezagent_actor/lib/ezagent/snapshot_store.ex`
- Modify: `apps/ezagent_actor/lib/ezagent/kind/server.ex`
- Modify: `apps/ezagent_actor/lib/ezagent/kind/snapshot.ex`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260801000300_remove_identity_cap_compatibility.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity_caps_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/behavior/identity_lifecycle_cold_load_test.exs`
- Delete obsolete cutover/user-store tests under
  `apps/ezagent_domain_identity/test/ezagent/identity/` and
  `apps/ezagent_domain_identity/test/ezagent/identity_caps/`.

**Cleanup migration:**

```elixir
def up do
  drop_if_exists table(:identity_cutover)
  alter table(:users), do: remove(:caps_json)
end

def down do
  alter table(:users), do: add(:caps_json, :text, null: false, default: "[]")

  create table(:identity_cutover, primary_key: false) do
    add :id, :string, primary_key: true
    add :activated_at, :utc_datetime_usec, null: false
    timestamps(type: :utc_datetime_usec)
  end
end
```

- [ ] Add RED tests proving users and non-users read the same Store authority,
  missing/corrupt Store rows fail readiness, and a snapshot/user row cannot
  resurrect a missing Store capability.
- [ ] Delete Cutover/UserStore code, config overrides, release/Mix entry points,
  caps_json fields/readers/writers, backfill/remint code, and dual-plane comments.
- [ ] Keep historical migration filenames/modules/DDL unchanged except for the
  already-approved narrow runtime module rename needed by replay.
- [ ] Add the cleanup migration and update user creation/bootstrap to create the
  user row without a capability column, then initialize Store explicitly.
- [ ] Run migrations from an empty partition plus identity/user/cold-load suites.
- [ ] Commit as `refactor(identity): make IdentityCaps Store the only authority`.

### Task 7: Make every identity mutation Store-first and projection-only

**Files:**

- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity_caps.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`
- Modify: `apps/ezagent_actor/lib/ezagent/kind/snapshot.ex`
- Modify: `apps/ezagent_actor/lib/ezagent/kind/server.ex`
- Modify: `apps/ezagent_actor/lib/ezagent/snapshot_store.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity_caps/store_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity_caps_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/behavior/identity_lifecycle_cold_load_test.exs`
- Test: `apps/ezagent_core/test/invariants/entity_caps_mutation_boundary_test.exs`
- Test: `apps/ezagent_core/test/invariants/entity_caps_access_gate_test.exs`

**Mutation ordering:**

```elixir
with {:ok, durable_caps} <- Store.update(holder_uri, mutation),
     :ok <- project_identity_slice(holder_uri, durable_caps),
     :ok <- project_snapshot(holder_uri, durable_caps) do
  {:ok, durable_caps}
end
```

Projection failure may report degraded projection, but must never roll back or
replace the committed Store authority with snapshot/live state. The existing
self-license authority lock stays around the bootstrap transition that needs it.

- [ ] Add RED fault-injection tests for Store write failure, live projection
  failure, snapshot projection failure, fresh bootstrap, and cold restart.
- [ ] Assert Store failure leaves both projections unchanged; projection failure
  leaves Store committed and the next load repairs projections from Store.
- [ ] Remove epoch branches, `:keep` paths, redundant post-commit Store mirrors,
  snapshot-to-Store fallback, and union semantics.
- [ ] For active rows, cold load replaces identity caps from Store. For a
  non-active status, use an empty effective set. A Store read error or missing
  established row fails readiness; missing is permitted only inside the
  uncommitted genesis transaction.
- [ ] Run the focused suites and mutation/access invariants.
- [ ] Commit as `fix(identity): enforce Store-first capability mutation`.

### Task 8: Preserve exact revoke/re-grant semantics without compatibility paths

**Files:**

- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity_caps.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity_caps_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity_caps/store_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/delivery_outbox_hardening_test.exs`
- Test: `apps/ezagent_core/test/e2e/unified_revocation_acceptance_test.exs`

- [ ] Write RED tests for stored-artifact resolution by logical identity,
  ignoring attacker-supplied signature metadata, exact absent-Store revoke,
  wrong holder/grantee/target/workspace, stale authority, revoked enqueue/drain,
  idempotent second revoke, and re-grant with a fresh effective UUID.
- [ ] Ensure one transaction locks the holder Store row, resolves and validates
  the actual signed artifact, inserts the ledger marker, removes the artifact,
  cancels matching pending outbox rows, and re-derives grantee projection.
- [ ] When no Store artifact matches, permit a marker only for the exact supplied
  current signed artifact whose holder/grantee/target/workspace all match.
- [ ] Do not special-case old/missing version data; malformed issued artifacts
  fail before mutation.
- [ ] Run the listed suites and acceptance test.
- [ ] Commit as `fix(cap): finalize exact per-grant revoke semantics`.

### Task 9: Add permanent source/schema ratchets

**Files:**

- Create: `apps/ezagent_core/test/invariants/clean_slate_grant_protocol_test.exs`
- Modify: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`
- Modify architecture baselines/allowlists only when the renamed runtime owner
  is the intended dependency.

**Forbidden identifiers:**

```elixir
@forbidden ~w(
  signing_version RevocationEpoch CapRevocationEpoch cap_revocation_epoch
  CapRevocationCutover cap_revocation_cutover Identity.Cutover
  identity_cutover_active_override IdentityCaps.UserStore
)
```

The ratchet also rejects runtime `users.caps_json` access. Exceptions are limited
to the ratchet itself, the historical migration that originally creates the
column/table, and the cleanup migration that removes them. No source exception
is permitted for application/config/test compatibility code.

- [ ] Write the invariant first and observe RED against the existing leftovers.
- [ ] Add a schema assertion that ledger/outbox grant IDs are UUID and non-null,
  and that current `users`/identity schema has no compatibility column/table.
- [ ] Remove every unjustified match until the invariant is GREEN; document the
  exact historical-migration exception list in the test.
- [ ] Run all architecture and invariant directories via `mix gate.arch`.
- [ ] Commit as `test(cap): ratchet clean-slate grant protocol`.

### Task 10: Add an executable empty-database clean-start gate

**Files:**

- Create: `apps/ezagent_core/lib/mix/tasks/ezagent.cap_revocation.verify_clean_start.ex`
- Modify: `config/test.exs`
- Modify: `mix.exs`
- Test: `apps/ezagent_core/test/mix/tasks/ezagent_cap_revocation_verify_clean_start_test.exs`

**Configuration seam:**

```elixir
default_database = "ezagent_pg_compat_test#{System.get_env("MIX_TEST_PARTITION")}"

config :ezagent_core, EzagentCore.Repo,
  database: System.get_env("EZAGENT_TEST_DATABASE", default_database)
```

**Alias contract:**

```elixir
"ci.clean_per_grant": [
  "cmd MIX_ENV=test mix ezagent.cap_revocation.verify_clean_start"
]
```

Include `ci.clean_per_grant` exactly once in `precommit`.

- [ ] Write RED unit tests for the safe database-name regex, exact environment
  propagation, child Repo-config assertion, cleanup-after-failure, and alias
  wiring. The Mix task module itself must not start umbrella applications.
- [ ] Implement an admin Postgrex connection that creates a unique database name
  accepted by `~r/\Aezagent_pg_compat_test_clean_[a-z0-9_]+\z/`; never interpolate
  an unchecked identifier.
- [ ] In `try/after`, run separate `System.cmd/3` children for migrate, seed,
  first application boot, and cold application boot. Give every child
  `MIX_ENV=test`, a unique `MIX_TEST_PARTITION`, and the exact
  `EZAGENT_TEST_DATABASE`; each child must first assert
  `Repo.config()[:database] == System.fetch_env!("EZAGENT_TEST_DATABASE")`.
- [ ] Terminate connections and drop only that exact validated database in
  `after`, including when a child exits non-zero.
- [ ] Run the focused Mix-task test, then `MIX_ENV=test mix ci.clean_per_grant`.
- [ ] Commit as `test(cap): gate clean database initialization`.

### Task 11: Reconcile documentation and remove stale operational instructions

**Files:**

- Modify: `docs/superpowers/specs/2026-08-01-per-grant-durable-revocation-clean-slate.md`
- Modify: `docs/superpowers/specs/2026-08-01-per-grant-durable-revocation-clean-slate.zh_cn.md`
- Modify/delete repository docs found by the Task 9 ratchet that instruct an
  operator to run either removed cutover.
- Do not rewrite historical handoff evidence files unless a live source ratchet
  explicitly owns them.

- [ ] Reconcile every design acceptance bullet with a test, gate, or source path.
- [ ] Keep English and Chinese documents structurally parallel and update status
  from design-complete to implementation-complete only after fresh gates pass.
- [ ] Document that development databases are disposable and must be recreated;
  do not publish a production upgrade/cutover procedure.
- [ ] Run markdown/source ratchets and commit as
  `docs(cap): document the sole per-grant revocation mechanism`.

### Task 12: Full verification, push, and leave the final PR open

- [ ] Re-read the design and this plan line by line; map every acceptance item to
  fresh command evidence or an exact source path.
- [ ] Run `mix format --check-formatted`.
- [ ] Run all touched owner-app suites with a unique partition.
- [ ] Run `MIX_ENV=test MIX_TEST_PARTITION=p2final mix gate.arch`.
- [ ] Run `MIX_ENV=test mix ci.clean_per_grant`.
- [ ] Run `MIX_ENV=test MIX_TEST_PARTITION=p2final mix ci.fast`.
- [ ] Run `MIX_ENV=test MIX_TEST_PARTITION=p2final mix precommit`; fix every
  issue in scope and rerun until green.
- [ ] Resolve the development Repo database from the effective dev config,
  print and assert the exact name is `ezagent_pg_compat_dev`, then run the
  repository-supported drop/create/migrate/seed sequence against that exact
  database. Never use a wildcard, environment-expanded target, or a broader
  PostgreSQL cleanup command.
- [ ] Boot the application once against the reinitialized development database
  and verify its capability Store, authority anchors, and seeds contain only the
  clean-slate schema/artifact shape.
- [ ] Review `git diff origin/main...HEAD`, `git status`, commit history, and
  verify there are no secrets, compatibility leftovers, or unrelated changes.
- [ ] Push `feat/p2-per-cap-revocation` to origin.
- [ ] Open a PR whose base is `main` and head is
  `feat/p2-per-cap-revocation`, including design, implementation, migration,
  risk, rollback-for-development, and exact test evidence.
- [ ] Confirm the final PR exists and leave it open. Do not merge it and do not
  merge `main` into the target branch as a delivery shortcut.

## Completion Definition

The goal is complete only when all twelve tasks are checked, the worktree is
clean, the target branch is pushed, every required gate has fresh green evidence,
and the open target-to-main PR is returned to the user. A green local branch
without that final PR is incomplete.
