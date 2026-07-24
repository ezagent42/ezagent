> **Task:** agent-display-name-profile
> **Branch:** `fix/agent-display-name-profile`
> **PR:** [#1570 — fix(world): persist agent display names](https://github.com/ezagent42/ezagent/pull/1570) (draft)
> **Dev:** Codex
> **returned_at:** 2026-07-24 20:11 +0800
> **deadline:** 2026-07-24 23:59 +0800
> **deadline_status:** deferred

## What changed

- Persist a human-readable Agent display profile at the generic fresh
  `TemplateSpawn` boundary; World continues to read it through its existing
  `EntityPresenter` path, so UUID URI names remain internal identifiers.
- Enforce unique Agent display names within a workspace, including deterministic
  suffix allocation and concurrent requests. The database and application both
  distinguish canonical Agent URIs from User profiles.
- Add PostgreSQL migration repair for already-applied early index versions,
  while fresh migration paths allow duplicate no-email User names.
- Make profile-write failures and post-write failures roll back only facts
  created by that spawn attempt: profile, worker, lineage/derivation receipts,
  workspace binding, config, flavor, grant, and creation inventory.
- Add focused Identity, Agent, Core provenance, migration, and World regression
  coverage, including non-transaction provenance writes and transaction races.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | Newly spawned named Agents persist a display name and the World directory shows it instead of a UUID. | met | `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`; `apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs` |
| 2 | Agent names are unique without affecting Users, including concurrent creation and Unicode bounds. | met | `apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`; `profile_concurrency_test.exs`; PostgreSQL migration-chain regression |
| 3 | Failed fresh spawns leave no facts created by that attempt while preserving pre-existing facts. | met | TemplateSpawn post-profile-failure and pre-existing-profile/lineage regressions; final focused run: TemplateSpawn 21/21 |
| 4 | Required full gate and browser manual test are green. | deferred | Isolated authenticated browser smoke test passed: a non-admin founder logged in and the Agent directory rendered `pr-1570-visual-agent` as the title with its entity URI secondary. `mix precommit` still has no terminal result in this environment, and the two-session Hello duplicate-role scenario remains untested. |

**Method friction:** project-local worktree dependencies and long-running full-suite scans prevented a machine-green return gate. The focused tests used isolated PostgreSQL partitions and explicit umbrella startup where needed; the full-gate/interactive evidence remains an open merge decision rather than being represented as green.

## Verification evidence

- Profile/concurrency focused suite: 18 passed.
- Full Agent TemplateSpawn focused suite: 21 passed.
- Core derivation/lineage and migration-chain focused suites: passed.
- World UUID display-name regression: passed.
- Fresh focused re-run completed successfully: the World regression explicitly
  reported `1 test, 0 failures`; the TemplateSpawn command also exited zero.
- Isolated manual World check: created and verified a non-admin founder, logged
  in, created `pr-1570-visual-agent`, and confirmed its human-readable name in
  `/identities/agents` rather than a UUID-only label. Authentication and
  directory captures were delivered with the return but intentionally remain
  outside Git.
- `git diff --check` and final independent code review: passed; review found no Critical or Important issue.

**Manual-test scope:** the browser-created Agent exercises the existing
`Workspace.create_agent` presentation path. TemplateSpawn profile persistence
is directly covered by the focused TemplateSpawn suite above; the dedicated
Hello two-session duplicate-role scenario is still deferred.

## Deferred follow-up / open decision

1. Re-run `mix precommit` in an uncontended CI environment and attach its run URL/status.
2. Manually exercise two Hello sessions with duplicate role names and confirm
   their deterministic unique display names in `/identities/agents`.

## Merge request

Draft PR [#1570](https://github.com/ezagent42/ezagent/pull/1570) is open against `main`.

- Rebase base: `b9b548c874556a2d58be7f161dca217c4a611035` (`origin/main` at return time).
- The branch is rebased onto that base.
- Two pre-existing local SDD report edits remain intentionally unstaged and are
  excluded from this return and PR.
