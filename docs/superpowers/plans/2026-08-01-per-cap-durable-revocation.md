# Per-cap Durable Revocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the complete P2a-P2d per-cap durable revocation contract from `/Users/h2oslabs/P2_KIMI_HANDOFF.md` on `feat/p2-per-cap-revocation`.

**Architecture:** A signed v2 capability carries a fresh framework-minted `grant_id`; an insert-only core ledger absorbs revocations. Authorization reads and every durable cap-set writer consult the same fail-closed epoch-aware ledger, while revoke resolves the signed stored artifact and changes ledger, Store, outbox, and grantee projection in one transaction. A prestart maintenance one-shot semantically re-mints the durable effective plane and atomically activates the epoch; the final phase mechanically renames runtime `EntityCaps` modules without renaming durable schema/config safe-list entries.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, ExUnit, Phoenix umbrella Mix tasks.

## Global Constraints

- Base is exactly `46a7b4ffcd6b30963f28e4ba6ca951c0b328aebd`; work only on `feat/p2-per-cap-revocation`.
- TDD for every behavior change: observe RED, implement minimally, observe GREEN.
- Run tests from the umbrella root with unique `MIX_TEST_PARTITION`; keep touched apps warnings-as-errors clean.
- `grant_id` is signature-covered but excluded from `Capability.identity_key/1`.
- All ledger reads fail closed; no negative/absence cache.
- Do not open a PR or merge main. Commit logical steps and push only the target branch.
- If the handoff contradicts current code, stop and report instead of inventing a different design.

---

### Task 1: Capability v2 protocol and additive serialization

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/capability.ex`
- Modify: `apps/ezagent_core/lib/ezagent/capability/normalize.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/signing.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/grant.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/authority.ex`
- Modify serializer/digest consumers found by the protocol-field ratchet
- Test: `apps/ezagent_core/test/ezagent/capability_test.exs`
- Test: `apps/ezagent_core/test/ezagent/cap/signing_test.exs`
- Test: `apps/ezagent_core/test/ezagent/cap/authority_verify_against_current_test.exs`

**Interfaces:**
- Produces `%Capability{signing_version: 1 | 2, grant_id: binary() | nil}`.
- Produces version-aware signing/verification: v1 has no grant ID, v2 requires it, all other combinations deny without raising.
- `Grant.issue_unchecked/2` and authority-anchor generation overwrite caller metadata with v2 plus a fresh UUID.

- [ ] Add failing tests for legacy defaults, serializer round trips, versioned signing bytes, illegal version combinations, fresh re-grant IDs, and anchor stamping.
- [ ] Run each focused test and confirm the expected RED reason.
- [ ] Add fields, normalization, serializers/digests, framework stamping, and total protocol validation.
- [ ] Run focused core suites and the authorize ratchet; format touched files.
- [ ] Commit the protocol slice.

### Task 2: Core revocation ledger and durable epoch

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/ecto/cap_revocation.ex`
- Create: `apps/ezagent_core/lib/ezagent/cap/revocation_ledger.ex`
- Create: `apps/ezagent_core/lib/ezagent/ecto/cap_revocation_epoch.ex`
- Create: `apps/ezagent_core/lib/ezagent/cap/revocation_epoch.ex`
- Create migrations under `apps/ezagent_core/priv/repo_pg/migrations/`
- Modify: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`
- Add focused schema/API/epoch tests under `apps/ezagent_core/test/ezagent/cap/`

**Interfaces:**
- `RevocationLedger.mark/1` inserts idempotently and never deletes.
- `RevocationLedger.revoked_grant_ids(workspace_uri, grant_ids)` returns the revoked subset or an error.
- `RevocationEpoch.state/0` returns `:inactive | :active | :unknown`; only the one-shot transitions inactive to active.

- [ ] Write and run RED tests for monotone markers, workspace-scoped batch reads, inactive/active behavior, and read-error denial.
- [ ] Add schemas, migrations, APIs, constraints, indexes, and tenant invariant entry.
- [ ] Run migrations and focused core tests.
- [ ] Commit ledger and epoch.

### Task 3: Universal write/read gates

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity_caps/store.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/authorize.ex`
- Test Store and EntityCaps suites plus `authorize_test.exs`.

**Interfaces:**
- One shared `revoked_artifacts_guard` runs under the existing row lock before all four Store writers: persist, update, backfill, activate.
- Authorization and durable effective reads issue one workspace-scoped batch ledger query and deny/filter on revoked IDs; errors deny.

- [ ] Write RED tests covering each of the four Store writers, a live-slice authorize denial, effective-set filtering, and ledger read errors.
- [ ] Implement the shared Store guard and batched authorize/load filters.
- [ ] Run focused core/domain suites and ratchet.
- [ ] Commit read/write gates.

### Task 4: Atomic revoke and outbox grant identity

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex`
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery_outbox/envelope.ex`
- Create migration adding outbox `grant_id` and `(workspace_uri, grant_id, status)` index.
- Extend entity-caps/grant/outbox tests.

**Interfaces:**
- Revoke transaction locks the holder row, resolves the real stored signed artifact by logical identity, marks its grant ID, removes it, cancels pending rows, and re-derives the index.
- If no Store match exists, only the exact current signed artifact for holder/grantee/target may create a marker.
- Outbox semantic identity and payload-reuse validation include `grant_id`; enqueue and drain reject revoked IDs early.

- [ ] Write RED tests for stored metadata ignoring, random/wrong/stale rejection, exact absent-store acceptance, outbox enqueue/drain denial, and atomic rollback.
- [ ] Implement outbox migration/identity checks and the single revoke transaction.
- [ ] Run P2a acceptance suites, touched apps warnings-as-errors, and ratchet.
- [ ] Commit revoke/outbox slice and record P2a evidence.

### Task 5: Maintenance-window re-mint one-shot

**Files:**
- Create a focused cutover/rebuild module under `apps/ezagent_domain_identity/lib/ezagent/identity/`.
- Create a Mix/release task under `apps/ezagent_domain_identity/lib/mix/tasks/`.
- Modify Store/outbox APIs only where required for transactional enumeration and cleanup.
- Add cutover tests under `apps/ezagent_domain_identity/test/ezagent/identity/`.

**Interfaces:**
- Holder enumeration is Store holders union distinct pending-absorb target URIs.
- One Repo transaction takes the advisory/table lock, reads all effective caps, validates current authority, re-mints v2 twins, computes a bidirectional semantic diff, wipes/rebuilds all listed projections, cancels materialized pending absorbs, and activates the epoch.
- Any unapproved loss/addition or ledger/authority failure rolls the transaction back.

- [ ] Write RED tests for pending-only holders, empty diff, fail-closed nonempty diff, rollback on injected crash, full v2 rebuild, anchors/admin self-license, and cold-restart revocation durability.
- [ ] Implement the one-shot and release/Mix entrypoint contract.
- [ ] Run P2b acceptance suites with transaction rollback assertions.
- [ ] Commit the one-shot.

### Task 6: Operator runbook and full activation acceptance

**Files:**
- Create English and Chinese parallel runbooks under `docs/`.
- Add/extend acceptance/invariant tests that pin one-shot-before-listener ordering and spec-v4 section 6.

- [ ] Document the stopped-serving-container writer exclusion and forbidden eval/Mix/console/restore/second-container writers.
- [ ] Pin the prestart invocation contract without modifying the separate deploy repo.
- [ ] Run the complete controlled-activation acceptance suite and record what remains for cc production canary/stable smoke.
- [ ] Commit P2b/P2c docs and acceptance.

### Task 7: Runtime rename `EntityCaps` to `IdentityCaps`

**Files:**
- Move runtime modules/files under `apps/ezagent_domain_identity/lib/ezagent/entity_caps*` to `identity_caps*`.
- Update runtime/test references, `config/config.exs`, actor-boundary ledger paths/hashes, arch scanner allowlist, architecture baseline manifest, and create-cap-grantee-index migration runtime call.
- Preserve table `identity_caps`, all constraints/indexes, migration module `CreateIdentityCaps`, and config key `:identity_caps_store` exactly.

- [ ] Add/adjust a safe-list invariant test before the rename.
- [ ] Perform the mechanical rename and update references.
- [ ] Run compile warnings-as-errors, rename invariants, domain suites, and ratchet.
- [ ] Commit P2d separately.

### Task 8: Final branch verification and delivery

- [ ] Re-read every P2a-P2d acceptance line and reconcile it to fresh evidence.
- [ ] Run `mix format --check-formatted`, touched-app suites, authorize ratchet, `mix ci.fast`, and `mix precommit` from the umbrella root.
- [ ] Review `git diff origin/main...HEAD`, commit any gate-only fixes logically, and confirm a clean worktree.
- [ ] Push `feat/p2-per-cap-revocation` to origin only; do not create a PR.
- [ ] Report phase status and exact acceptance/gate evidence.
