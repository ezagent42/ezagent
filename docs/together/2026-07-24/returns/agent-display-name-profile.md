> **Task:** agent-display-name-profile
> **Branch:** `fix/agent-display-name-profile`
> **PR:** [#1570 — fix(world): persist agent display names](https://github.com/ezagent42/ezagent/pull/1570) (draft)
> **Dev:** Codex
> **returned_at:** 2026-07-24 22:35 +0800
> **deadline:** 2026-07-24 23:59 +0800
> **deadline_status:** deferred

## What changed

- Persist a human-readable Agent display profile at the generic fresh
  `TemplateSpawn` boundary; World continues to read it through its existing
  `EntityPresenter` path, so UUID URI names remain internal identifiers.
- Enforce unique Agent display names within a workspace, including deterministic
  suffix allocation and concurrent requests. The database and application both
  distinguish canonical Agent URIs from User profiles.
- Add one PostgreSQL migration which first deterministically repairs legacy
  duplicate Agent names (`Builder`, `Builder-2`, …) and then creates the
  Agent-only display-name index. Duplicate no-email User names remain valid.
- Make profile-write failures and post-write failures roll back active products
  created by that spawn attempt: profile, worker, active lineage cache,
  workspace binding, config, flavor, grant, and creation inventory. The
  derivation/provenance edge is deliberately retained as append-only audit
  history of the failed attempt.
- Add focused Identity, Agent, Core provenance, migration, and World regression
  coverage, including strict fresh-spawn rollback and transaction races.

## Scope-repair decision

- Provenance remains append-only: a fresh spawn that fails after profile
  insertion compensates its active products, but does not erase its
  `:spawned_by` derivation edge. Failed attempts are audit facts. The temporary
  Core delete APIs were removed rather than relaxing that invariant.
- Because the service has not shipped and has no legacy database state, the PR
  now contains one final Agent-only display-name migration rather than three
  sequential corrective migrations. This repair is recorded in
  `b259ecf73`.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | Newly spawned named Agents persist a display name and the World directory shows it instead of a UUID. | met | `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`; `apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs` |
| 2 | Agent names are unique without affecting Users, including concurrent creation and Unicode bounds. | met | `apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`; `profile_concurrency_test.exs`; PostgreSQL single-migration regression |
| 3 | Failed fresh spawns clean up active products while preserving pre-existing facts and append-only provenance audit history. | met | TemplateSpawn post-profile-failure and pre-existing-profile/lineage regressions; final focused run: TemplateSpawn 21/21 |
| 4 | Required full gate and browser manual test are green. | blocked locally | `mix gate.arch` is green after remediation (Core 676/676, Identity 4/4, External Mirror 39/39, Session 7/7). `mix ci.local` is blocked before tests by the repository pnpm supply-chain policy: `es5-ext@0.10.64` needs explicit build-script approval. The isolated authenticated browser smoke test passed; the specific two-session Hello duplicate-role scenario remains untested. |

**Method friction:** the initial full-gate attempts were interrupted by environment boot instability. A later isolated run completed `mix precommit`; only the dedicated two-session Hello duplicate-role manual scenario remains open.

## Verification evidence

- Profile/concurrency focused suite: 18 passed.
- Full Agent TemplateSpawn focused suite: 21 passed.
- Core derivation/lineage and single-migration focused suites: passed.
- World UUID display-name regression: passed.
- The isolated migration test seeds two legacy Agents with the same
  `(workspace_uri, display_name)`, migrates successfully, verifies the stable
  `Builder` / `Builder-2` repair, and verifies the Agent-only unique index.
- Review remediation: `TemplateSpawn` was split into focused rollback and
  behavior-overlay helpers (main module now 1000 LOC); undocumented
  `record_lineage_with_status/2` is marked internal; and the provenance-delete
  API was removed. A clean re-run of `mix gate.arch` passed: Core 676/676,
  Identity 4/4, External Mirror 39/39, and Session 7/7.
- A first architecture-gate attempt timed out in an existing production-AST
  scan while this machine was resource-contended. Its isolated rerun passed
  (9/9 in 26.5s), followed by a clean complete `mix gate.arch` run.
- `mix ci.local` was retried under the installed Node v22.23.1 toolchain. It
  reaches `pnpm install`, then stops before tests because the checked-in pnpm
  supply-chain policy has not approved `es5-ext@0.10.64`'s build script. No
  dependency policy or lockfile was changed for this PR.
- Fresh focused re-run completed successfully: the World regression explicitly
  reported `1 test, 0 failures`; the TemplateSpawn command also exited zero.
- Isolated manual World check: created and verified a non-admin founder, logged
  in, created `pr-1570-visual-agent`, and confirmed its human-readable name in
  `/identities/agents` rather than a UUID-only label. Evidence is versioned
  with this return:
  [authenticated non-admin founder](evidence/pr1570-authenticated-founder.png)
  and [Agent-directory display name](evidence/pr1570-agent-directory-display-name.png).
- `git diff --check` and final independent code review: passed; review found no Critical or Important issue.

**Manual-test scope:** the browser-created Agent exercises the existing
`Workspace.create_agent` presentation path. TemplateSpawn profile persistence
is directly covered by the focused TemplateSpawn suite above; the dedicated
Hello two-session duplicate-role scenario is still deferred.

## Deferred follow-up / open decision

1. Manually exercise two Hello sessions with duplicate role names and confirm
   their deterministic unique display names in `/identities/agents`.
   Attempted again on 2026-07-24 against the isolated database, but
   `mix phx.server` aborted before Phoenix listened because the system default
   SessionTemplate seed failed with `{:workspace://system, :holder_revoked}`.
   No Hello-session screenshot can be honestly produced until that unrelated
   boot invariant is repaired.
2. The data-normalizing migration intentionally keeps its repaired names when
   rolled back; `down/0` removes the unique-index enforcement but does not
   reconstruct ambiguous historical duplicate names. This is covered by the
   migration round-trip test and should be stated in deployment notes.
3. Run the full suite in the CI image or a local environment where the existing
   pnpm build-script approval policy is available. The local `ci.local` run
   cannot reach any test without that pre-existing project configuration.

## Merge request

Draft PR [#1570](https://github.com/ezagent42/ezagent/pull/1570) is open against `main`.

- Rebase base: `2cf16f2a4` (`origin/main` at return time).
- The branch is rebased onto that base.
- Two pre-existing local SDD report edits remain intentionally unstaged and are
  excluded from this return and PR.
