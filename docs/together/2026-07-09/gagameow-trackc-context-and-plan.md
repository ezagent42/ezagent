# gagameow Track C Context and Execution Plan

date: 2026-07-09
owner: gagameow
worktree: /home/huangjiajia/ezagent/.worktrees/gagameow-dogfooding-audit-2026-07-08
branch: gagameow-dogfooding-audit-2026-07-08
rebased_on: origin/main @ 63877f425
pr: https://github.com/ezagent42/ezagent/pull/1247

## Purpose

This document fixes the working context before continuing implementation and
testing. It records:

- what yesterday's task asked for;
- what yesterday actually produced;
- how today's team plan changes the goal;
- the final execution order and verification requirements for today's work.

It is intended as the stable reference for the later return document:
`docs/together/2026-07-09/returns/gagameow-trackc-fix.md`.

## Yesterday's Task Requirements

Yesterday's task was a dogfooding audit: verify whether ezagent can be used to
develop ezagent. It was explicitly an audit task, not a broad repair task. A
failure counted as a valid result only if the exact breakpoint and structural gap
were recorded.

The task was split into three tracks:

1. Track A: verify an ezagent-hosted agent can make a real repository change and
   produce a real PR.
2. Track B: verify an ezagent-hosted agent can generate a plugin-shaped artifact
   that follows the repo's plugin contract.
3. Track C: verify ezagent can author, publish/discover, install, and use a
   socialware definition.

Additional requirements:

- work in a new branch and isolated worktree;
- record the implementation plan, actual execution, results, blockers, and
  follow-up reasoning;
- update `main`, rebase the current branch, and re-test;
- distinguish real blockers from false blockers caused by incomplete
  understanding of existing framework capabilities.

## Yesterday's Actual Output

Track A partially succeeded.

- A product-hosted orchestrator agent successfully wrote a marker file into the
  repo.
- The first write landed in the original main checkout
  `/home/huangjiajia/ezagent`, because the agent defaulted to that cwd/branch.
- After being given the absolute audit worktree path, the agent wrote to the
  correct worktree.
- Result: product-hosted repo mutation works, but dogfooding needs an explicit
  worktree/cwd guard.

Track B succeeded as evidence, but the scaffold was not retained as final code.

- The agent produced a minimal `ezagent_plugin_dogfood_audit` scaffold during
  the dogfood run.
- It compiled and passed the plugin wiring invariant pre-rebase with an explicit
  scratch-plugin exemption.
- After rebase, the scratch app was removed from final branch code because the
  PR is an audit return, not a runtime plugin PR.
- Result: plugin-shaped artifact generation works; final evidence remains in
  the return document and screenshots.

Track C did not complete.

- The orchestrator-mediated request to create/install socialware did not produce
  socialware rows.
- A later status-check message was persisted in the UI, but delivery to the
  agent failed with `reason=:unauthorized`.
- Result: this proves the orchestrator-mediated route failed at
  session-to-agent dispatch authorization. It does not prove socialware authoring
  or installation is impossible through existing non-orchestrator paths.

Post-rebase test status from yesterday:

- `mix compile`: passed.
- `SHELL=/bin/bash mix ezagent.socialware.check`: passed.
- Socialware manifest paired narrow tests passed:
  `manifest_yaml_test.exs + manifest_seed_test.exs` -> `16 tests, 0 failures`.
- Plugin wiring invariant passed.
- Full `SHELL=/bin/bash mix precommit` was blocked by a flaky/environment-
  sensitive `WorldConversationTest` at
  `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1374`.
  The same failure also reproduced on updated `main`, so it was not attributed
  to the dogfooding audit PR.

## Today's Plan Interpretation

The 2026-07-09 dev-together plan makes gagameow's task the day's top priority:
fix Track C so the dogfooding development loop becomes green on all three
surfaces.

The plan's required scope for gagameow is:

1. Fix socialware author/install failure.
2. Fix `@mention` dispatch returning `:unauthorized`, suspected to relate to the
   `#161 A2 held-cap receive` path.
3. Continue the `#1256` design thread:
   - accept Q1: PTY is also a stateless executor; state lives in the folder
     referenced by the recipe, and conversation context is replayed from PG;
   - account for Q3: role cardinality should distinguish `one` vs `many`.
4. Verify the viewer role uniqueness concern:
   - how does `role_name_conflict` interact with hello's `fill:human viewer`
     role?
   - can multiple anonymous visitors coexist without routing bugs?
5. Add or define a Track A guard:
   product-internal agents must receive an explicit worktree and must not
   silently operate in the main checkout.

The key adjustment from yesterday is that Track C can no longer be evaluated only
by asking an orchestrator to do it. Today's validation must exercise the existing
socialware system directly as well as the product-mediated path.

## Final Task Arrangement

### Phase 0: Baseline and Evidence Setup

Goal: make later results attributable.

Actions:

- Confirm current worktree, branch, `origin/main`, and PR head.
- Re-run the minimum baseline checks before editing:
  - `mix compile`
  - `SHELL=/bin/bash mix ezagent.socialware.check`
- Create today's return file when execution starts:
  `docs/together/2026-07-09/returns/gagameow-trackc-fix.md`.

Expected output:

- Baseline command results copied into the return file.
- Any pre-existing failure separated from today's changes.

### Phase 1: Reproduce and Isolate `@mention :unauthorized`

Goal: turn yesterday's runtime symptom into a small reproducible test or script.

Actions:

- Locate the session message send / mention routing path.
- Reproduce a session with an orchestrator-like member.
- Send first and second mention messages.
- Capture whether the second delivery fails with `:unauthorized`.
- Inspect the required cap for the agent receive action and whether the caller
  has the needed held cap or carried ctx cap.

Expected output:

- A failing regression test if the bug is code-level and reproducible.
- If not reproducible in tests, a documented runtime reproduction with exact
  commands/UI steps and logs.

Success condition:

- `@mention` either delivers successfully, or the failure is surfaced explicitly
  and classified with the missing cap/checkpoint.

### Phase 2: Validate Socialware Author -> Publish -> Install Without Orchestrator

Goal: prove whether existing socialware capabilities can complete Track C
outside the broken orchestrator path.

Actions:

- Use existing code paths rather than ad hoc writes:
  - `Ezagent.Socialware.DefinitionRegistry`
  - world `workspace.template.save`
  - world `session.create`
  - `mix ezagent.socialware.import`
  - `mix ezagent.workspace.create_session`
- Start with the most deterministic path:
  manifest/import or direct existing conformance seed, then create a session
  from that definition.
- Verify installation state:
  - installed socialware entry exists;
  - expected roles/materialized members exist;
  - expected views are available or view caps are present.

Expected output:

- A green path that proves author/publish/install works without relying on the
  orchestrator agent, or a precise failure category:
  Definition conformance, publish/governance authorization, create-session,
  role materialization, view cap, or public route rendering.

Success condition:

- One complete socialware author/install/use path is demonstrated and recorded.

### Phase 3: Product-Mediated Track C

Goal: return to the original dogfooding requirement after the primitives are
known.

Actions:

- Run local Phoenix from this worktree.
- Use world UI to create/install a minimal socialware flow where possible.
- Use screenshots for:
  - authored or selected socialware;
  - session creation/install;
  - members/views after materialization;
  - `@mention` delivery success.

Expected output:

- Evidence that ezagent product surfaces can complete Track C, or evidence that
  the remaining break is a specific UI/action wiring issue.

Success condition:

- In ezagent, complete socialware author -> publish/save -> install, then
  successfully dispatch an `@mention`.

### Phase 4: Role Cardinality and Viewer Uniqueness

Goal: answer today's design follow-up without bundling speculative refactors.

Actions:

- Read current socialware role validation and role materialization code.
- Check where `role_name_conflict` is enforced.
- Check how hello declares `fill:human viewer`.
- Determine whether multiple anonymous viewers are represented as many users in
  one role, or whether the current role model forces singleton role names.

Expected output:

- A written conclusion:
  - no bug found;
  - confirmed product bug with reproduction;
  - or design gap requiring `one|many` role cardinality.

Success condition:

- `#1256` follow-up can be updated with Q1/Q3 and viewer uniqueness conclusion.

### Phase 5: Worktree Guard for Product-Internal Agents

Goal: prevent the Track A failure mode where an agent writes into the main
checkout.

Actions:

- Locate where agent cwd/worktree is chosen or displayed.
- Prefer a narrow guard over a broad redesign:
  - inject the explicit worktree into dogfooding agent setup;
  - or add a validation/test that product-internal agents created for repo work
    must carry an explicit worktree path;
  - or surface active cwd/branch before file mutation if no structural path
    exists yet.

Expected output:

- A test or gate if the code has an existing place to enforce it.
- Otherwise a documented issue/follow-up with exact insertion point.

Success condition:

- The main-checkout write failure is no longer silent.

## Verification Requirements

Minimum commands before returning:

- `mix compile`
- `SHELL=/bin/bash mix ezagent.socialware.check`
- Targeted tests added or touched for:
  - mention dispatch authorization;
  - socialware install/materialization;
  - role cardinality/viewer uniqueness if changed;
  - worktree guard if changed.
- `SHELL=/bin/bash mix ezagent.check_invariants`
- Relevant scans for any security/URI changes, including `uri_query.scan` if
  touched code constructs URI string keys or changes dispatch/cap paths.
- `SHELL=/bin/bash mix precommit`

Known risk:

- `WorldConversationTest` at
  `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1374` was
  flaky on latest main during yesterday's verification. If it still blocks
  `precommit`, today's return must include:
  - exact command;
  - seed;
  - whether it reproduces on `main`;
  - whether it is connected to today's code changes.

## Return Artifact Requirements

Today's return must be written to:

`docs/together/2026-07-09/returns/gagameow-trackc-fix.md`

It must include:

- current branch/head and rebase base;
- command log summary;
- screenshots or paths for product-mediated verification;
- per-phase results;
- blocker classification:
  real product bug, test-only flake, incomplete framework use, or out-of-scope;
- PR URL and final head SHA;
- any issue or follow-up branch recommendation.

## Current Status Before Execution

- Local `main` and `origin/main` were at `96af00d4d` when this plan was first
  written; before PR submission the branch was rebased again onto
  `origin/main @ 63877f425`.
- Branch `gagameow-dogfooding-audit-2026-07-08` was rebased on top of that main
  without conflicts.
- PR #1247 was force-with-lease updated to head
  `44ab3dd0852d55dc8679e41d929267b04faf8afa`.
- No business-code changes for today's task have been made yet.
