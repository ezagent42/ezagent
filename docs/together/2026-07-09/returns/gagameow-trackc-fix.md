# gagameow Track C Fix Return

returned_at: 2026-07-09
deadline: 2026-07-09 EOD
deadline_status: met
owner: gagameow
branch: gagameow-dogfooding-audit-2026-07-08
worktree: /home/huangjiajia/ezagent/.worktrees/gagameow-dogfooding-audit-2026-07-08
base: origin/main @ 63877f425
pr: https://github.com/ezagent42/ezagent/pull/1247

## Scope

Continue the 2026-07-08 dogfooding audit by completing Track C:

- socialware author -> publish/save -> install -> use;
- `@mention` delivery after yesterday's `:unauthorized` failure;
- viewer role cardinality / `role_name_conflict` assessment;
- Track A worktree/cwd guard assessment;
- final verification and return evidence.

Reference plan:
`docs/together/2026-07-09/gagameow-trackc-context-and-plan.md`.

## Baseline

- Worktree clean before today's edits except today's planning/return docs.
- Current branch head before implementation: `44ab3dd08`.
- Current base before PR submission: `origin/main @ 63877f425`.
- `mix compile`: passed.
- `SHELL=/bin/bash mix ezagent.socialware.check`: passed.
  - `autoservice-tier1`: 15 assertions pass.
  - `chat`: 15 assertions pass.
  - `hello`: 15 assertions pass.
  - `kanban`: 15 assertions pass.
  - `orchestrator`: 15 assertions pass.
  - `socialware`: 15 assertions pass.
  - Final: `6 definition(s) OK`.

## Execution Log

- Created context/plan document:
  `docs/together/2026-07-09/gagameow-trackc-context-and-plan.md`.
- Created this return skeleton before implementation work.
- Investigated yesterday's `agent.receive :unauthorized` against the current
  held-cap receive design:
  - `agent.receive` / `user.receive` are cap-exempt at CapBAC and authorize in
    handler through `Ezagent.Session.MemberReceive.authorize/1`.
  - authority is the recipient's preloaded `:identity` sibling member-cap over
    `ctx.caller` (the source session), not the roster and not delivery-presented
    caps.
  - at-join member-cap grant is intentionally async to avoid Session self-deadlock.
- Added regression coverage for immediate post-join delivery:
  `apps/ezagent_domain_session/test/integration/send_echo_decouple_test.exs`.
- Added socialware install/use chain coverage:
  `apps/ezagent_plugin_world/test/ezagent/world/socialware_install_test.exs`.
- Added multiple anonymous visitor coverage:
  `apps/ezagent_domain_socialware/test/ezagent/socialware/anon_admission_test.exs`.
- Extended file-flavor cwd guard coverage to codex:
  `apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs`.
- Rebased the PR branch onto `origin/main @ 63877f425` before final PR
  preparation and re-ran verification.
- During post-rebase verification, the existing PR-6 web path exposed a real
  world `session.create` gap:
  - world conversation action discarded the current caller caps and called
    `Ezagent.Workspace.create_session/3` with an empty cap set;
  - the workspace facade did not forward a caller deadline to the router call,
    so py-backed session materialization could hit the default 5s call timeout;
  - the web PR-6 fixture user needed a durable `workspace.create_session` cap in
    the same source `LiveAuth` reads, instead of relying on an invariant-breaking
    auth fallback.
- Fixed that path narrowly:
  - world `create_session_result/6` now threads caller caps and a 30s
    create-session deadline;
  - `Ezagent.Workspace.create_session/3` forwards positive `deadline_ms` values
    into dispatch context;
  - PR-6 setup seeds the installer user with a workspace-scoped
    `create_session` cap.

## Results

- Track C `@mention` / receive authorization:
  - Current rebased code passes a no-wait join -> immediate send -> delivery
    regression. The old failure is not reproducible after rebase in the focused
    path tested today.
  - Root-cause risk is real: receive authorization depends on held member-cap,
    while member-cap grant is async. This is framework behavior, not a missing
    understanding issue. The added test pins the user-visible contract.
- Socialware author -> publish/save -> install -> use:
  - Covered by writing a definition through `DefinitionRegistry.write_definition/2`,
    preparing the install template through `Ezagent.World.SocialwareInstall`,
    creating a real session through `Ezagent.Workspace.create_session/3`, and
    reading installed definitions via both `Installation` and world
    `ConversationData`.
- Viewer / anonymous cardinality:
  - Multiple anonymous visitors can join the same public socialware session and
    both can read the feed.
  - Conclusion: anonymous visitors are distinct anon user members. They are not a
    single shared `viewer` role_name slot. `role_name_conflict` remains relevant
    to explicit role assignment, not to raw anonymous public-view admission.
- Worktree / cwd guard:
  - Existing design accepts empty cwd for file flavors, but defaults
    `project_cwd` to the per-agent config dir. It does not silently inherit the
    operator's current checkout/main worktree.
  - Coverage now includes both `cc` and `codex`.
- #1256 design notes:
  - No production design change was landed today. Current conclusion remains:
    PTY execution should be stateless, durable state belongs in the recipe/session
    config layer, and context should be reconstructed from session history/PG
    replay rather than terminal process state.
- Post-rebase PR-6 create-session path:
  - The web manifest install flow now uses the same CapBAC source as production
    `LiveAuth` and no longer depends on empty caps or timing luck.
  - The fix preserves the chokepoint invariant: caps are still checked by
    dispatch/behavior authorization; `LiveAuth` was not changed to bypass the
    existing durable user-cap source.

## Verification

- `mix compile`: passed.
- `SHELL=/bin/bash mix ezagent.socialware.check`: passed, 6 definitions OK.
- `SHELL=/bin/bash mix test apps/ezagent_domain_session/test/integration/send_echo_decouple_test.exs --seed 1`:
  passed, 4 tests.
- `SHELL=/bin/bash mix test apps/ezagent_plugin_world/test/ezagent/world/socialware_install_test.exs --seed 1`:
  passed, 5 tests.
- `SHELL=/bin/bash mix test apps/ezagent_domain_socialware/test/ezagent/socialware/anon_admission_test.exs --seed 1`:
  passed, 7 tests. Note: emitted a DB sandbox owner-exit log from async identity
  cascade after one test; it did not fail the suite.
- `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs --seed 1`:
  passed, 19 tests.
- Combined targeted verification:
  `SHELL=/bin/bash mix test apps/ezagent_domain_session/test/integration/send_echo_decouple_test.exs apps/ezagent_plugin_world/test/ezagent/world/socialware_install_test.exs apps/ezagent_domain_socialware/test/ezagent/socialware/anon_admission_test.exs apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs --seed 1`
  passed, 35 tests.
- Post-rebase expanded targeted verification:
  `SHELL=/bin/bash mix test apps/ezagent_domain_session/test/integration/send_echo_decouple_test.exs apps/ezagent_plugin_world/test/ezagent/world/socialware_install_test.exs apps/ezagent_domain_socialware/test/ezagent/socialware/anon_admission_test.exs apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1374 --seed 19953`
  passed.
  - workspace: 19 tests, 0 failures.
  - session: 4 tests, 0 failures.
  - socialware: 7 tests, 0 failures.
  - plugin_world: 17 tests, 0 failures.
  - web PR-6 focused run: 41 tests, 40 excluded, 0 failures.
- Invariant + PR-6 guard verification:
  `SHELL=/bin/bash mix test apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1374 --seed 55815`
  passed.
  - invariant: 1 test, 0 failures.
  - plugin_world: 12 tests, 0 failures.
  - web PR-6 focused run: 41 tests, 40 excluded, 0 failures.
- `SHELL=/bin/bash mix precommit`: passed.
  - Full umbrella verification completed with 0 failures.
  - Existing noisy warning/error logs appeared from fault-injection tests,
    sandbox ownership cleanup, missing local `claude` binary checks, and
    allowlisted plugin-locality debt; none failed the gate.
- Final doc-update precommit rerun:
  `SHELL=/bin/bash mix precommit` was rerun after this return document was
  updated. It completed all apps, but `ezagent_web` reported 1 failure in the
  full umbrella run while the CLI app still passed.
  - `SHELL=/bin/bash mix test --failed`: reran the recorded failing web test and
    passed, 1 test, 0 failures.
  - `SHELL=/bin/bash mix test apps/ezagent_web/test --seed 365002`: reran the
    full web suite with the same seed and passed, 316 tests, 0 failures.
  - Classification: not a Track C functional blocker. Current evidence points
    to the known web full-suite async DB sandbox cleanup class rather than a
    reproducible regression in the changed code.

## Blockers and Follow-Ups

- No confirmed hard blocker remains for today's Track C validation.
- Remaining risk: async member-cap grant can still be a race class if future
  receive delivery stops preserving the tested contract. Keep the immediate
  post-join delivery regression in place.
- If the DB sandbox owner-exit log in `anon_admission_test.exs` becomes a CI
  failure, add explicit test draining/waiting around async identity cascade
  side effects instead of weakening the admission assertions.
- Product workflow follow-up: handoff prompts for product-internal agents should
  continue to pass the explicit feature worktree. Code-level fallback prevents
  silent main checkout inheritance, but it does not infer the intended worktree.
