# Handoff: Split PR #1110 Into Reviewable PRs

Owner: jjkysy
Date: 2026-07-01
Source branch / PR: https://github.com/ezagent42/ezagent/pull/1110

## Context

#1110 exists because #1020 came from a fork branch that could not be updated
directly after main moved forward. The work was rebased and pushed into the main
repository as `feat/kanban-agent-e2e`, then opened as #1110.

#1110 is an integration/salvage branch. It is not a merge unit.

Current state:

- rebased onto latest main after #1107 and #1104
- GitHub reports it as mergeable
- CI is still red: tests show 0 failures, but `mix precommit` exits non-zero
  because warnings/error logs remain

## Task

Split #1110 into smaller PRs. Do not try to merge #1110 whole.

Start with:

1. **World UI surface substrate**
   - move `nav_surfaces/0` and `session_tabs/0` out of core plugin contract
   - World owns reading/filtering via a UI surface provider
   - no kanban business behavior, no GitHub gateway, no default PM/dev recipes

2. **Generic role-agent materialization substrate**
   - `SessionAgentMaterialize`
   - cap grant landing through the existing CapBAC chokepoint
   - minimal cc role spawn support
   - no `pm-coordinator` / `dev-together` product recipes

Then split separately:

3. **Default PM/dev-together recipes**
   - decide ownership first: platform default pack in domain-agent, or product
     policy in plugin/default-pack layer

4. **Kanban + GitHub business plugins**
   - `Behavior.Kanban`, kanban manager, GitHub gateway, PR sync, World Kanban UI

5. **PM persona and evidence docs**
   - skill/persona and E2E evidence after code shape is clear

## Development Discipline

- One PR, one ownership boundary.
- Do not mix core/domain substrate, plugin business logic, UI refactor, persona,
  and E2E evidence in one PR.
- If touching core/domain, state the architectural invariant in the PR body.
- Keep split PRs rebased on main and green before asking for merge.
- Treat #1110 as source material, not a thing to rescue by force.

## DoD

At least one split PR is opened today with:

- a narrow title and body
- explicit included/excluded scope
- CI status
- no unrelated docs/evidence dump
- a short note explaining which slice of #1110 it came from
