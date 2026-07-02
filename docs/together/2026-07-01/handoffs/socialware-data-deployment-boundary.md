# Handoff: Socialware Data Split and Deployment Shape

Owner: gaga
Reviewer: jjkysy
Date: 2026-07-01
Branch: `feat/socialware-data-deployment-shape-0701`

## Context

#1106 proved that AutoService Tier-1 can run on the current architecture, but it
also exposed a broader product-shape issue: a socialware application cannot live
as one-off seed code. AutoService is one example. Kanban is the other current
example.

The question is not "where do we put AutoService seed code?" The question is:

> How do we split socialware definition data from installer/runtime deployment,
> so multiple socialware apps such as AutoService and kanban can be packaged,
> installed, tested, and promoted consistently?

Current examples:

- AutoService: persona, KB corpus, session/routing setup, and cc-orchestrator
  wiring are too concentrated in `scripts/autoservice_tier1_seed.exs`.
- Kanban: board workflow, PM/dev roles, recipes, UI surface, GitHub gateway, and
  evidence docs are mixed in #1110 and need split PRs.

Read first:

- `docs/together/contributing/socialware-data-deployment-boundary.md`
- `docs/together/contributing/README.md` P6
- `.claude/skills/ezagent-developer/references/anti-patterns.md`
- `scripts/autoservice_tier1_seed.exs`
- `docs/e2e/scenario-13-autoservice-end-to-end.md`
- `docs/together/2026-07-01/handoffs/jjkysy-split-pr-1110.md`

## Task

Produce a concrete proposal and first implementation slice for socialware data
split and deployment shape.

Minimum expected output:

1. Define the socialware package boundary:
   - persona / soul / AgentTemplate data
   - KB/resource fixture data
   - SessionTemplate and routing data
   - role recipes and capability requests
   - UI/surface declaration
   - external integration config such as GitHub gateway, if applicable
2. Define the installer/deployment boundary:
   - create workspace / install package
   - ingest resources
   - grant capabilities through CapBAC
   - instantiate sessions/agents through supported product/API paths
   - run smoke/E2E verification
3. Apply the boundary to both examples:
   - AutoService: identify what moves out of seed code first.
   - Kanban: identify what belongs in package data versus plugin runtime versus
     deployment/install step.
4. Open the first PR slice, preferably moving at least one AutoService or kanban
   business artifact out of code/seed and into data/package form.

Do not solve all socialware packaging in one PR. This task is to establish the
shape and land one small proof.

## Reviewer Focus for jjkysy

Review against the generalized socialware boundary, not only AutoService:

- Does the proposal work for both AutoService and kanban?
- Does it separate definition data from install/deploy/runtime state?
- Does it keep generic substrate out of business plugins?
- Does it avoid moving business logic into core/domain?
- Is the first PR slice small enough to merge independently?

## DoD

- PR opened by gaga.
- jjkysy review requested and blocking.
- A socialware package/deployment boundary doc or code slice is included.
- AutoService and kanban are both mapped against the proposed boundary.
- At least one business artifact moves toward data/package form, or the PR
  explicitly proves why the first slice must be a docs/spec slice.
- PR body includes a boundary checklist and remaining follow-ups.
