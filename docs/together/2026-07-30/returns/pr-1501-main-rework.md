# Together Return: PR #1501 current-main rework

> **Task:** rework PR #1501 against current `main`
> **Branch:** `fix/pr1501-main-rework`
> **PR:** #1501 existing branch prepared for an exact-lease update
> **Dev:** Codex
> **returned_at:** 2026-07-30 17:18 +0800
> **deadline:** not provided
> **deadline_status:** out_of_scope

## Frozen base and scope

- Final replay base: `origin/main@b3eb4df7c`.
- Isolated worktree:
  `/home/huangjiajia/ezagent/.worktrees/pr-1501-main-rework`.
- The original PR branch and its three worktrees were retained untouched for
  forensic recovery.
- User-owned dirty files in the primary `main` worktree were not modified.

## What's done

- Added a core-owned validated reader for pending `:absorb_cap` deliveries.
  Malformed envelopes fail the entire read instead of being silently skipped.
- Added deterministic capability semantic identities and a partial unique
  PostgreSQL index that permits only one pending semantic absorb per target.
  Applied/dead rows release the identity for a future delivery.
- Preserved strict byte-identical idempotency-key behavior while making
  semantic pending reuse atomic under concurrency.
- Added checked `EntityCaps` readers and tagged effective views that combine
  held capabilities with validated pending absorbs. The readers preserve the
  #1621 epoch contract and never fall back from an active authoritative store
  read error.
- Moved member join, member-cap migration, and orchestrator reconciliation to
  effective views. Read failures fail closed; repeated reconciliation no
  longer reattempts an already-pending semantic delivery.
- Restored the current-main scoped-cap cascade baseline that had been
  incorrectly changed during an earlier merge conflict.
- Ratcheted only the exact invariant allowlists changed by the new checked
  adapter and core outbox reader.

## Review hardening

- Pending semantic identity includes the target authority `key_id`, so a stale
  generation cannot suppress a newly issued artifact after key rotation.
- Effective views use a DB-only checked current-authority verifier before
  five-axis deduplication. Stale artifacts are discarded; an unreadable
  authority store fails the entire read closed. The persisted path does not
  call a Kind or dispatch across an actor boundary.
- Active identity-store and legacy-user malformed capability JSON returns an
  explicit checked-read error instead of being silently treated as an empty
  authority set. `nil`, empty strings, and JSON `null` retain their legacy
  empty-set compatibility.
- Migration/gate documentation now states that a validated pending absorb is
  effective but not yet confirmed in the held store.

## Verification

- TDD authority-generation rollover:
  - outbox direct rollover failed before the fix and passes after it;
  - real Orchestrator reconciliation failed with 39 pending rows instead of 75
    before the fix and passes after it;
  - checked authority seam, stale held/pending filtering, and unreadable-store
    fail-closed coverage pass.
- Malformed-capability TDD:
  - both active Store and legacy UserStore returned `{:ok, []}` before the fix;
  - both now return checked errors, with null/empty compatibility controls.
- Final focused verification on a fresh database after replaying onto
  `origin/main@b3eb4df7c`:
  - core authority and invariants: 24 tests, 0 failures;
  - identity entity-cap and outbox paths: 51 tests, 0 failures;
  - session consumers: 17 tests, 0 failures.
- `mix ci.fast` passes:
  - actor: 1 test, 0 failures;
  - core: 691 tests, 0 failures;
  - identity: 4 tests, 0 failures;
  - external mirror: 39 tests, 0 failures;
  - session: 8 tests, 0 failures.
- A fresh-database `mix precommit` run reached core at 2 doctests plus 2,263
  tests with 0 failures. It then reproduced the existing monolithic
  cross-application state leak: identity reported 640 tests with 7 failures,
  workspace reported 405 tests with 2 failures, and later suites showed the
  same shared database/process contamination. The redundant local run was
  stopped after this diagnosis; PR CI remains the full-suite authority.
- Fresh migration through `20260730140000`: passes.
- `git diff --check`: passes.

## Dependency observations

`mix deps.get` reported existing advisories for Bandit, hpax, Phoenix, Plug,
Postgrex, and Swoosh, and reported `erlexec` as retired. Dependency upgrades
were intentionally kept out of this capability-delivery PR.

## Merge request

After final verification and independent review, update the existing
`fix/cap-pending-held-convergence-idempotence` branch only with the frozen
remote lease `f0d1d14748f0b56ee530036da97c6d234fcbe01d`. The backup branch
`backup/pr1501-remote-f0d1d147` preserves the pre-rewrite remote head.
