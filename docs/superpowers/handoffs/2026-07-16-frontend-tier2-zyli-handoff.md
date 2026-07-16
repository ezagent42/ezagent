# Handoff — Frontend Tier-2 (zyli) — lightweight reminder

**Owner:** zyli · **Weight:** lightweight (reminders + one design decision) · **When:** when Tier-2 real-integration is scheduled (NOT today; today's P1 CI gate #1432 is merged).

## Context
Tier-1 Playwright + independent frontend CI landed in **#1432** (merged `8538b9863`). 验收 = ACCEPT-WITH-FOLLOWUPS. The **dispatch-action** half of the anti-mock-drift contract is genuinely drift-proof (single-sourced through `Ezagent.World.DispatchContract`). Three follow-ups remain for Tier-2 — carry these into the Tier-2 work.

## Follow-ups (from #1432 验收, task #179)

### 1. State-shape drift-proofing — the real Tier-2 task (a design decision to make)
Today `apps/ezagent_plugin_world/lib/ezagent/world/state_contract.ex`'s `@fixtures` are **hand-authored** minimum-state maps, and `StateContract` has **zero production consumers** (only `e2e_fixtures.ex` + its test). So if a real backend state-builder changes shape, `--check` stays green and the frontend passes against a stale shape — exactly the mock-drift the Tier-1 handoff §4 said "不许手写". Tier-1 acceptance consciously deferred this; Tier-2 must close it.
- **Decide (A vs B), based on where the Tier-2 state-builders land:**
  - **A) Project from the real backend state-builder** — once Tier-2 assembles real state, generate the fixture shape from that source (like `DispatchContract` does for actions) so a shape change reds `--check`.
  - **B) Designate `StateContract` as the authoritative schema** — make the Tier-2 state-builders test *against* `StateContract` (it becomes the single source the builders conform to), and gate that they match.
- Deliverable: whichever path, a real state builder ↔ fixture link with a **drift gate that can demonstrate a red** (the #1432 gate discipline — a gate that can't red is worthless).

### 2. Kill the 3-action parallel copy (mechanical)
`DispatchContract.@direct_actions ~w(sessions.join layout.manage agent.api_key.put)` is a parallel copy — `world_live.ex` matches these three via inline string literals in the function heads (~lines 229/243/263), not via `DispatchContract`. So 3 of 65 actions can drift silently. Route WorldLive's direct actions through `DispatchContract` too.

### 3. Harness key mismatch (mechanical)
Fixtures project `plugin_nav` (snake_case) but `mountWorld` destructures `pluginNav` (camelCase, `main.tsx:70/138`); `(pluginNav || [])` swallows the undefined, so plugin-nav rendering is **never covered** and the projected `plugin_nav` field is dead in the harness. Map `plugin_nav → pluginNav` (or emit camelCase) and add a plugin-nav render assertion.

## Not in scope
Tier-2 real-integration design itself is a separate scoping (this handoff only carries the #1432 follow-ups). The state-shape A/B decision above is the gating one — do it first.
