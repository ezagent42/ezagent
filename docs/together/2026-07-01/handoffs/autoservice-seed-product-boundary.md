# Handoff: Move AutoService Tier-1 Out of Seed-As-Product

Owner: gaga
Reviewer: jjkysy
Date: 2026-07-01
Branch: `feat/autoservice-seed-product-boundary-0701`

## Context

#1106 proved that the current architecture can run the AutoService Tier-1 flow.
That was valuable, and it avoided the previous wrong direction of pushing
AutoService business logic into core/domain.

The remaining problem is the carrier: `scripts/autoservice_tier1_seed.exs` now
contains AutoService business content and wiring:

- support-agent persona text
- fixed KB corpus / `ZEPHYR-7731`
- default kb/agent/session names
- session routing setup
- session ↔ orchestrator binding
- `McpRegistry.register/2`
- `SessionManager.ensure_started/1`

That is acceptable as an E2E harness. It is not the correct long-term product
shape.

Read first:

- `docs/together/contributing/seed-vs-product-boundary.md`
- `docs/together/contributing/README.md` P6
- `.claude/skills/ezagent-developer/references/anti-patterns.md`
- `scripts/autoservice_tier1_seed.exs`
- `docs/e2e/scenario-13-autoservice-end-to-end.md`

## Task

Produce the first concrete step toward making AutoService Tier-1 a data/package
composition instead of seed-owned product code.

Minimum expected split:

1. Move support persona out of Elixir string constants into definition data.
   Candidate carriers: AgentTemplate content, soul markdown, or socialware
   config/fixture data.
2. Move the fixed KB corpus out of Elixir module attributes into fixture/resource
   data that the seed ingests.
3. Keep `scripts/autoservice_tier1_seed.exs` as an installer/verifier:
   it should import/select artifacts, ingest corpus, create session, grant caps,
   and call supported paths.
4. Document which remaining wiring is still private stitching and what product/API
   path should replace it.

Do not solve every AutoService product gap in this PR. The goal is a clean first
slice that changes the carrier of business content.

## Reviewer Focus for jjkysy

Review against the boundary rule, not just tests:

- Is any AutoService business text still being introduced as Elixir code when it
  should be data?
- Does the PR keep seed as installer/verifier?
- Does it avoid moving business logic into core/domain?
- Does it identify any remaining private runtime stitching explicitly?
- Is the slice small enough to merge independently?

## DoD

- PR opened by gaga.
- jjkysy review requested and blocking.
- Support persona and/or KB corpus is no longer hard-coded in
  `scripts/autoservice_tier1_seed.exs`.
- Seed still runs as an E2E harness.
- Regression coverage or a documented verification command proves the seed still
  wires the Tier-1 scenario.
- PR body includes a seed/product boundary checklist.
