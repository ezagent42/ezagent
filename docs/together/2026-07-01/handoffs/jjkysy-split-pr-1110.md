# Handoff: Split PR #1110 Into Reviewable Functional PRs

Owner: jjkysy
Date: 2026-07-01
Source PR: https://github.com/ezagent42/ezagent/pull/1110
Supersedes merge mechanics for: https://github.com/ezagent42/ezagent/pull/1020

## Why #1110 Exists

#1020 came from the fork branch `jjkysy/ezagent-biz:feat/kanban-agent-e2e`.
After main moved forward, that PR became conflicting and we could not update the
fork head directly from the main repository.

To keep the work reviewable and preserve the rebase effort, the branch was
rebased onto current `main`, pushed into the main repository as
`ezagent42/ezagent:feat/kanban-agent-e2e`, and opened as #1110. The original
#1020 was commented as superseded for merge mechanics.

#1110 is therefore an integration branch and a salvage branch. It is not a final
merge unit.

## Current Status

- #1110 has been rebased again after #1107 and #1104 landed.
- The rebase conflict was in World UI (`apps/ezagent_plugin_world/assets/src/main.tsx`).
  Resolution: keep the new #1104 topbar shell and only preserve #1110's plugin
  nav contribution by appending plugin nav items into the existing primary nav.
- A deterministic whitespace failure in two e2e evidence files was fixed.
- Do not merge #1110 as-is. It is too broad and should be split first.

## Why It Must Be Split

#1110 mixes several ownership boundaries in one PR:

1. Generic agent runtime substrate.
2. Default PM/dev-together role recipes and seed policy.
3. World plugin UI surface substrate.
4. Kanban and GitHub business plugins.
5. PM persona skill plus large e2e/docs evidence.

Those are not one review unit. They have different owners, different risk
profiles, and different architectural questions. The most important question is
whether `pm-coordinator` and `dev-together` are ezagent platform defaults or
kanban/dev-together product policy. Until that is decided, `DefaultRecipes`
should not be merged casually into `ezagent_domain_agent`.

## Required Split Plan

Please split #1110 into smaller PRs in this order.

### PR A: World UI Surface Substrate

Goal: move World-only UI surface concepts out of core.

Include:
- `apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex`
- World-side reading/filtering of plugin `nav_surfaces/0` and `session_tabs/0`
- tests for plugin nav/session tabs/UI surface provider
- minimal core contract cleanup that removes `nav_surfaces/0` and `session_tabs/0`
  from `Ezagent.Plugin`

Do not include:
- kanban business behavior
- GitHub gateway
- pm/dev-together default recipes
- large e2e evidence

Acceptance:
- core does not own World sidebar/session-tab concepts
- World keeps fail-closed shape filtering
- tests pass against the post-#1104 World shell

### PR B: Generic Role-Agent Materialization Substrate

Goal: land the generic mechanism for materializing a role agent into a session.

Include:
- `Ezagent.Agent.SessionAgentMaterialize`
- generic grant landing via the existing CapBAC chokepoint
- `Ezagent.Agent.GrantRecipeCaps` if still needed as the grant wrapper
- minimal cc spawn/role support required by the generic path
- focused tests proving a generic role can be materialized without kanban

Do not include:
- `pm-coordinator` / `dev-together` product recipes
- kanban board-scoping policy, except as a generic override mechanism test if it
  can be kept domain-agnostic
- World UI or kanban UI

Acceptance:
- no direct spawn/registry shortcuts outside sanctioned facades
- no behavior-specific product names required for generic runtime correctness
- CapBAC grants still go through the existing chokepoint

### PR C: Default PM / Dev-Together Recipe Ownership

Goal: make an explicit ownership decision before landing `DefaultRecipes`.

Two acceptable directions:
- If these are ezagent platform defaults, keep them as a default pack in
  `ezagent_domain_agent`, with plugin behavior names referenced as strings and
  no compile dependency on kanban/github plugins.
- If these are dev-together/kanban product policy, move them out of the domain
  substrate and into the owning plugin/default-pack layer.

Acceptance:
- PR description states which ownership model is chosen and why
- requested caps are narrow and least-privileged
- `project_cwd` behavior is documented and tested

### PR D: Kanban + GitHub Business Plugins

Goal: land the actual workflow-agent product feature.

Include:
- `ezagent_plugin_kanban` behavior/actions/connectors/relay
- `ezagent_plugin_github` gateway, credentials, PR sync
- World Kanban data/actions/UI integration after PR A
- board-scoped PM materialization only after PR B/C decisions are settled

Acceptance:
- no cross-plugin direct calls where dispatch is required
- board-scoped caps are verified
- no resource Kind regression for kanban boards
- tests cover bind-session, relay, PR sync, and CapBAC boundaries

### PR E: PM Persona And Evidence Docs

Goal: land docs and skill/persona artifacts after the code shape is clear.

Include:
- `.claude/skills/pm-coordinator/SKILL.md`
- e2e evidence and user guides
- dev-together handoff/return process docs

Acceptance:
- docs match the final split implementation
- no large evidence dump is bundled with runtime substrate PRs

## Development Discipline Going Forward

Please keep future PRs reviewable:

- One PR should have one primary owner boundary. Do not mix core/domain substrate,
  plugin business logic, UI refactor, persona prompts, and e2e evidence in one PR.
- If a PR touches core or domain, state the architectural invariant it changes or
  preserves in the PR body.
- Do not use a broad e2e branch as the merge unit. Use it as an integration proof,
  then split clean PRs from it.
- Rebase long-running branches daily before stacking more work.
- Keep PR titles honest. A title like `docs(...)` must not change production UI.
- Run `mix precommit` before marking a PR merge-ready. `warnings-as-errors` is a
  real gate, not noise.
- If a feature needs a default policy, decide and document the owner before
  landing it in a shared domain module.

## Current Recommended Next Step

Start with PR A and PR B. They unlock the rest and are the easiest to review
without deciding the full kanban workflow product shape.
