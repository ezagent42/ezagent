# Kanban / World / Website Rebase And Merge Analysis

Date: 2026-07-01
Context: follow-up after the 2026-06-30 close stack. The user asked to rebase the
remaining PRs first, then decide whether to merge whole PRs or cherry-pick the
agent runtime and plugin UI pieces.

## Rebase Results

| PR | Branch | Result | Notes |
|---|---|---|---|
| #1107 | `feat/website-framework-hello-prod-0630` | rebased and force-pushed | Conflicts were limited to `docs/website-demo/index.html`, `login.html`, and `version/2026-06-30-website-roadmap-v1.md`. Resolution: keep `main`/#1103 design assets and retain only #1107's unique hello support files. CI passed after rebase. |
| #1104 | `docs/world-ui-redesign-prototype-0630` | rebased and force-pushed | One conflict in `Identities.tsx`. Resolution: keep #1105 user-management entry/action constants and add #1104 agent shell/schema constants. CI passed after rebase. |
| #1020 | fork PR `jjkysy/ezagent-biz:feat/kanban-agent-e2e` | could not update fork head; replacement #1110 opened | Rebased branch was pushed to `ezagent42/ezagent:feat/kanban-agent-e2e` and opened as #1110. Original #1020 was commented as superseded for merge mechanics. One conflict in `WorldLive`: resolved by keeping the extracted `Ezagent.World.Jsonable` path and deleting the stale local `jsonable/1` helper. CI later failed in `mix precommit`; tests reported 0 failures, but the warnings-as-errors compile gate exposed warnings that must be cleaned before merge. |

## Immediate Merge Guidance

### #1107 Website Hello Support

Recommended action: merge whole PR after CI remains green.

Reason:
- After rebase, #1107 no longer overwrites #1103's design/demo files.
- Remaining files are isolated: static images, `hello-demo.html`, `world-demo.html`,
  `tokens.css`, package lock, a notes doc, and `scripts/refresh_hello_site.exs`.
- It is not on the critical path for kanban runtime or World UI. Merge independently.

### #1104 World UI IM Refactor

Recommended action: merge whole PR only after visual/product review accepts the
new shell. Do not cherry-pick only parts of #1104 unless we explicitly want a
docs-only prototype.

Reason:
- The code is coherent as a World UI refactor: React shell, loading skeleton,
  routes/data tests, screenshots, and structure checks move together.
- The only rebase conflict with #1105 was resolved locally by preserving both
  user-management behavior and the new agent UI constants.
- It should land before kanban plugin UI if the team wants kanban tabs/navigation
  to target the new IM shell rather than the old UI.

Risk:
- The PR title still under-describes scope (`docs(world)`), while the diff changes
  production UI and a workspace deadline path. Before merge, retitle or record the
  scope in the PR body.

## #1110 / #1020 Split Analysis

#1110 is mechanically mergeable after rebase, but its CI is not green and it
should not be treated as a clean single-purpose PR. The first commit bundles
multiple axes:

1. agent runtime substrate
2. plugin UI substrate
3. CLI ergonomics
4. cc spawn/role support
5. default pm/dev-together recipes
6. kanban-specific affordances used by the later plugin commits

Therefore, if we cherry-pick, we should split by file ownership, not by original
commit.

### Slice A: Agent Runtime Substrate

Candidate files:
- `apps/ezagent_domain_agent/lib/ezagent/agent/session_agent_materialize.ex`
- `apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex`
- `apps/ezagent_domain_session/lib/ezagent/session/message_composer.ex`
- cc spawn/role support under `apps/ezagent_plugin_cc/lib/ezagent/template/`
- CLI verbs/tests needed to drive the runtime path:
  - `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex`
  - `apps/ezagent_cli/lib/ezagent_cli/exec.ex`
  - `apps/ezagent_cli/lib/ezagent_cli/tree_builder.ex`
  - related CLI integration tests

Merge condition:
- Keep this substrate generic: role names are data, not code branches.
- No kanban/pm/dev-together names should be required for runtime correctness.
- Tests should prove a generic role materializes into a session without a kanban
  board present.

Current concern:
- `DefaultRecipes` in the domain agent app contains concrete `pm-coordinator` and
  `dev-together` recipes with Kanban/GitHub capability strings. This is not core
  leakage, but it is domain-layer product/default policy. If we want a clean
  runtime substrate, split `DefaultRecipes` out of Slice A or reduce it to a seed
  hook that plugins/default packs can feed.

### Slice B: Plugin UI Substrate

Candidate files:
- `apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex`
- `apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_data.ex` surface
  reading functions
- World tests for `plugin_nav_surfaces`, `plugin_session_tabs`,
  `ui_surface_provider`
- Core plugin contract cleanup in `apps/ezagent_core/lib/ezagent/plugin.ex` that
  removes `nav_surfaces/0` and `session_tabs/0` from core and leaves
  `config_surface/0` there
- `apps/ezagent_core/lib/ezagent/plugin/surface_validator.ex` only if it is still
  needed for `config_surface/0`; otherwise this can stay with the current core
  plugin contract.

Merge condition:
- World owns World-only UI concepts. Core must not validate or know
  World-specific nav/session tabs.
- Plugins may contribute plain functions, but World does the read-time filtering.

Assessment:
- This is directionally good. It moves UI concepts out of core rather than
  leaking plugin UI into core. It can be merged as a standalone substrate before
  kanban business logic, especially after #1104.

### Slice C: Kanban / GitHub Business Plugin

Candidate files:
- `apps/ezagent_plugin_kanban/**`
- `apps/ezagent_plugin_github/**`
- `.claude/skills/pm-coordinator/SKILL.md`
- kanban/github E2E docs

Merge condition:
- Only after Slice A and B are present, or as a whole #1110 merge if we accept the
  coupled branch.
- Verify CapBAC: PM/dev agent caps are narrow, board-scoped, and granted through
  the existing grant chokepoint.
- Verify no direct spawn/registry calls were added outside sanctioned facades.

Assessment:
- This is the actual product feature. It is too broad to cherry-pick blindly, but
  it can merge once CI is green and architecture review signs off the substrate
  boundaries.

### Slice D: Default PM / Dev-Together Recipes

Candidate files:
- `apps/ezagent_domain_agent/lib/ezagent/agent/default_recipes.ex`
- `apps/ezagent_domain_agent/lib/ezagent/agent/default_recipe_seed.ex`
- `apps/ezagent_domain_agent/lib/ezagent/agent/default_agent_seed.ex`
- `apps/ezagent_domain_agent/lib/ezagent_domain_agent/application.ex`
- related tests

Decision point:
- If these are "platform defaults" for ezagent's built-in development workflow,
  domain-agent is acceptable as a default-pack owner, but it must stay stringly
  referenced to avoid compile dependency on plugins.
- If these are kanban/dev-together product policy, move them to a plugin/default
  pack and keep domain-agent as the generic seed mechanism only.

Current recommendation:
- Do not merge Slice D alone until Allen confirms the ownership model. This is
  the main boundary question in #1110. It is not a core leak, but it is a domain
  default-policy decision.

## Recommended Order

1. Merge #1107 after CI green. It is isolated and no longer conflicts with #1103.
2. Decide #1104 product acceptance. If accepted, merge #1104 before kanban UI so
   kanban surfaces target the new World shell.
3. For kanban workflow agent, do not cherry-pick by original commit and do not
   merge #1110 until its warnings-as-errors CI failure is fixed. Either:
   - Preferred conservative path: create a new PR with Slice A + Slice B only,
     leaving Slice C/D for the next PR.
   - Faster path: merge #1110 whole after CI and architecture review, explicitly
     accepting domain-agent ownership of `DefaultRecipes`.
4. If choosing cherry-pick, start with Slice B (plugin UI substrate) and the
   generic part of Slice A. Keep DefaultRecipes and Kanban/GitHub plugin business
   out until the ownership decision is made.

## Current Decision

Do not merge #1110 yet just because it is rebased and mergeable. It is a good
replacement for #1020 and a good integration branch for CI, but the clean merge
unit should be decided after the `DefaultRecipes` ownership question is answered
and after the warnings-as-errors failure is fixed.
