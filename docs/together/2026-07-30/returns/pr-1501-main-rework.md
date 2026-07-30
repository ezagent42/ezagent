# Together Return: PR #1501 current-main rework

> **Task:** rework PR #1501 against current `main`
> **Branch:** `fix/pr1501-main-rework`
> **PR:** #1501 replacement branch prepared locally; no remote rewrite performed
> **Dev:** Codex
> **returned_at:** 2026-07-30 14:36 +0800
> **deadline:** not provided
> **deadline_status:** out_of_scope

## Frozen base and scope

- Frozen base: `main@81a90855c`.
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

## Commits

1. `2f27d467e` — `docs(cap): redesign PR 1501 against current main`
2. `984526ae7` — `docs(cap): plan PR 1501 current-main rework`
3. `28080baa6` — `test(session): restore scoped-cap cascade baseline`
4. `a2ec39a1d` — `feat(cap): expose validated pending absorb view`
5. `4f3f1a935` — `fix(cap): make pending absorb identity atomic`
6. `3e4202734` — `feat(cap): merge held and pending effective caps`
7. `e17c529bd` — `fix(session): converge grants across held and pending caps`
8. `819bc617a` — `test(cap): ratchet effective-cap invariants`

## Verification

- Pending outbox seam: 15 tests, 0 failures.
- Atomic semantic identity suite: 18 tests, 0 failures, including concurrent
  enqueue coverage.
- Effective-cap reader suite: 46 tests, 0 failures.
- Session caller suite plus reconciler helper coverage: 25 tests, 0 failures.
- Final focused run:
  - `ezagent_domain_identity`: 46 tests, 0 failures.
  - `ezagent_domain_session`: 17 tests, 0 failures.
- `mix ezagent.check_invariants`: all in-scope invariants clean.
- Exact access/self-store ratchets: 14 tests, 0 failures.
- `git diff --check`: passed before each commit.

`mix precommit` was run as required. Its forced compilation passed and the
largest suite, `ezagent_core`, completed with 2 doctests + 2241 tests and zero
failures. Reusing the already-exercised `pr1501r` database then caused
cross-application state pollution in later suites:

- The 26 affected identity tests passed with zero failures on a fresh
  `pr1501iso` partition.
- One unrelated domain-agent file still had 3 failures on a fresh partition.
  The exact same file failed identically on untouched `main@81a90855c` with a
  separate fresh partition (22 tests, 3 failures). Those failures concern
  template-spawn rollback return shapes and an unsupported config-dir cleanup,
  not capability delivery/effective reads. They were not folded into #1501.

There is also a pre-existing test-support compile warning:
`EzagentPluginGithub.GitHubAppJwt.generate/0` is unavailable from
`ezagent_plugin_git_workflow/test/support/github_live_case.ex`. It prevents a
clean repository-wide warnings-as-errors claim but is not introduced here.

## Dependency observations

`mix deps.get` reported existing advisories for Bandit, hpax, Phoenix, Plug,
Postgrex, and Swoosh, and reported `erlexec` as retired. Dependency upgrades
were intentionally kept out of this capability-delivery PR.

## Merge request

The replacement branch is locally complete and based on current main. No
force-push, PR branch rewrite, or deletion of the old worktrees was performed.
Before updating PR #1501, push `fix/pr1501-main-rework` and choose whether to
retarget the existing PR or open a clean replacement PR.
