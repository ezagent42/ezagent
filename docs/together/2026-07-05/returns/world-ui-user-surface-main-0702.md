# Return — World UI User Surface Main 0702

> **Task:** `world-ui-user-surface-main-0702`
> **Branch:** `work/world-ui-user-surface-main-0702`
> **PR:** #1128 — https://github.com/ezagent42/ezagent/pull/1128
> **Dev:** Codex
> **returned_at:** 2026-07-05 10:40 +0800
> **deadline:** 2026-07-02 23:59 +0800
> **deadline_status:** late

## What's Done

- Refined the World conversation user surface and preserved the main-targeted PR
  scope in #1128.
- Preserved the earlier July 4 service-start/login seed finding: legacy
  socialware install records no longer block the default `session://system/default/main`
  seed path after definition record upgrades.
- Merged the current `origin/main` tip `90e8ee29756299c69daa60bba21c5e1d345fd0d7`
  into the PR branch and resolved the new conflict.
- Added this explicit dev-together return file because no prior return was found
  for PR #1128 / `work/world-ui-user-surface-main-0702`.

## Conflict Resolution

The only content conflict after merging latest `origin/main` was:

- `apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex`

Resolution:

- Kept main's content-hash/freeze-pin install model and the new `(session, ref)`
  install identity semantics.
- Treated an existing install pointer for the same `ref` as idempotent
  `{:ok, :exists}`. This covers older install bodies that lack
  `definition_content_hash` or still point at legacy definition subjects without
  re-triggering seed collisions.
- Dropped the prior narrow logical-body comparison from this branch because the
  current mainline model intentionally holds an already-installed frozen revision
  unless `repoint_template_installs/4` is called.

## DoD Reconciliation

No matching handoff file was found for this exact PR/branch, so the DoD below is
reconstructed from the PR scope, the July 4 service-start/login follow-up, and
the dev-together return gate.

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | World conversation user surface remains intact on the main-targeted branch. | met | Prior PR evidence: `world_ia_test.mjs`, world mount gate, Vite build, and world/web route tests were recorded in PR #1128. |
| 2 | Login/default seed issue is covered after socialware definition upgrades. | met | `PATH=/tmp/ezagent-pg-bin:$PATH POSTGRES_PORT=5432 mix test apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs apps/ezagent_domain_session/test/ezagent/socialware/content_hash_install_test.exs apps/ezagent_domain_session/test/ezagent/socialware/pin_on_install_test.exs apps/ezagent_domain_session/test/integration/repair_freeze_pin_test.exs` — 18 tests, 0 failures. |
| 3 | PR branch is integrated with current `main` and has no unresolved merge conflicts. | met | Merge commit `2e60e1544c5601feab4fcdd8df9931cb5e794356`; rebase/merge base `origin/main` `90e8ee29756299c69daa60bba21c5e1d345fd0d7`; `rg "<<<<<<<|=======|>>>>>>>" apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex` found no markers; `git diff --check` passed. |
| 4 | Local final gate is green before handoff. | met | `PATH=/tmp/ezagent-pg-bin:$PATH POSTGRES_PORT=5432 mix precommit` — exit 0 on 2026-07-05 after resolving the world admission test socket assign and `IdentityDataTest` sandbox fixture gaps. |
| 5 | GitHub PR-head CI is green on the returned head. | pending | GitHub creates the new `precommit + check_invariants` run only after pushing this return commit. Use PR #1128 checks for the final run URL/status after push. Previous head `3b22ac39` was green, but it is not authoritative for this returned head. |

**Method friction:** The branch had no explicit return file tied to PR #1128, and
the advisory check can pass without proving the return belongs to the PR's actual
task. The return process would be clearer if the PR template carried the expected
return-file path before review.

## Branch And Gate Status

- **Head at return creation:** `2e60e1544c5601feab4fcdd8df9931cb5e794356`
- **Merged main tip:** `90e8ee29756299c69daa60bba21c5e1d345fd0d7`
- **Local targeted conflict gate:** passed, 18 tests / 0 failures.
- **Local full gate:** passed — `PATH=/tmp/ezagent-pg-bin:$PATH POSTGRES_PORT=5432 mix precommit`, exit 0.
- **GitHub CI:** pending the post-return push.

## Merge Request

- Merge PR #1128 (`work/world-ui-user-surface-main-0702` → `main`) after the
  pushed head's `precommit + check_invariants` check is green and review is
  accepted.
- This branch is already merged onto the current `origin/main` tip observed at
  return time, so there should be no remaining GitHub merge conflict after push.
