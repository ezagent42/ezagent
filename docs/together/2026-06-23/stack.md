# dev-together merge stack — 2026-06-23 (lead) · refreshed (all returns in)

_returned handoffs in analyzed merge order · dependencies · conflict check · reconciliation_

> `push` orders + analyzes only; merging happens in `close` (lead → `main`).
> Base `origin/main` at this push = `2d642254`. **All returns are now in** —
> including the late-but-critical #902-crux fix (#912). Timestamps below are each
> PR's **last-commit time** (the authoritative basis, not relay time).

## Returns analyzed (merge stack)

| Order | Task | Dev | PR | last-commit (+08) | deadline | mergeable | status |
|---|---|---|---|---|---|---|---|
| 1 | `session-create-orchestrator-decouple` (#902-crux fix) | Codex (rev6 by Claude+Allen) | [#912](https://github.com/ezagent42/ezagent/pull/912) | 21:37 (late) | — | MERGEABLE (draft) | ✅ stacked — **lead reviewing** |
| 2 | `agent-flavor-headless-protocol-api` | gagameow | [#907](https://github.com/ezagent42/ezagent/pull/907) | 18:14 on_time | 20:00 | MERGEABLE | ✅ stacked |
| 3 | `world-hello-convergence` | zhaomaota97 | [#910](https://github.com/ezagent42/ezagent/pull/910) | 20:04 (marginally late) | 20:00 | MERGEABLE | ✅ stacked |
| 4 | `socialware-creator-agent-config` (+ #904 demo supplement) | FatNine | [#905](https://github.com/ezagent42/ezagent/pull/905) | 17:39 on_time | 20:00 | MERGEABLE | ✅ stacked — return lead-recorded |
| 5 | `world-deploy-e2e-pg` | zylideveloper | [#902](https://github.com/ezagent42/ezagent/pull/902) | 18:09 on_time | 20:00 | UNKNOWN (recompute) | ✅ stacked |

> **on_time/late by PR commit time** (deadline 20:00 +08): #905/#902/#907 on_time;
> #910 marginally late (20:04); #912 late (21:37) but it is the emergent #902-crux
> fix, not a planned-task slip. #904 (20:54) is a demo supplement (see below).

## Merge order (by dependency/conflict/risk — NOT pure time)

**1. `#912` → 2. `#907` → 3. `#910` → 4. `#905` → 5. `#902`.**

- **`#912` first** — it is the structural fix for `#902`'s root-cause crux
  (create→orchestrator coupling + snapshot-deleting rollback). Landing it first
  makes the world E2E flow actually correct and gives the other branches a fixed
  base to rebase onto. Lead is reviewing it now (gates below).
- **`#907`** — pure agent/plugin + protocol-api; disjoint; fully gated (342/0).
- **`#910`** — shares `behavior/workspace.ex` + hello files with `#912` → rebase on
  `#912`.
- **`#905`** (+ `#904` demo) — owns `world_live.ex` agent create/config region.
- **`#902`** — docs/evidence + `b3b23b74` picker; shares `world_live.ex` with
  `#905` → rebase; decide the `b3b23b74` split (splitting clears the conflict).

## Conflict analysis (cross-branch)

- **`world_live.ex`** — touched by `#905` **and** `#902`. The one world-side code
  conflict; sequence (land `#905`, rebase `#902`), or split `#902`'s `b3b23b74` out.
- **`behavior/workspace.ex`** — touched by `#910` **and** `#912`; plus both touch
  the `hello` plugin (different files). → rebase `#910` on `#912`.
- **`#907`** — disjoint from all world/session branches.
- **`#912`** does **not** touch `world_live.ex` (it touches `home_live.ex`); no
  conflict with `#905`/`#902` on the world UI.
- Doc-only low-risk: `#902` re-touches `docs/together/2026-06-23/` `plan.md` +
  `handoffs/*`; resolve as doc merges. Each PR owns its own `returns/*`.

## #912 lead review (in progress — this is the de-facto CI; see CI note)

- `mix ezagent.check_invariants` → **EXIT=0**, all in-scope invariants clean.
- Focused architectural-gate tests **pass, 0 failures**: gate-15 anti-recurrence
  (`no_plugin_transport_readiness_primitives_test`), `transport_readiness_test`
  (domain_agent), `session_create_orchestrator_decouple_test`, `cap_mint_test`
  (fail-closed), routing `resolver`/`rule_store`, `scenario_32` (G1 retarget).
- Migration verified: `plugin_cc/live_join_registry.ex` (118L) +
  `readiness_adapter.ex` (45L) **deleted**; primitives recreated in `domain_agent`
  (`live_join_registry.ex` + `transport_readiness.ex`, agent-URI keyed). cc MCP
  socket/channel/server stay in `plugin_cc` (correct).
- **Full `mix precommit` running** as the final gate before approve+merge.

## CI note (why nothing "blocks")

The only GitHub Actions workflow is `dev-together-return-advisory.yml` — a
**non-blocking** advisory (it shows `pass` even on `#905`, which lacks a return
file). **There is no test/precommit CI in Actions.** Therefore the merge gate is
**local `mix precommit` + `check_invariants`**, run per-PR by the lead. PR
`BLOCKED` state = branch-protection `REVIEW_REQUIRED`, cleared by lead approve
(+ `--admin` if needed), not a CI failure.

## Returned-vs-stacked reconciliation (every return accounted for)

| Task / PR | Owner | Return file | Ledger status |
|---|---|---|---|
| `session-create-orchestrator-decouple` #912 | Codex | `returns/session-create-orchestrator-decouple.md` ✅ | **stacked** (the #902-crux fix; emergent, not a planned task) |
| `agent-flavor-headless-protocol-api` #907 | gagameow | `returns/agent-flavor-headless-protocol-api.md` ✅ | **stacked** |
| `world-hello-convergence` #910 | zhaomaota97 | `returns/world-hello-convergence.md` ✅ | **stacked** |
| `socialware-creator-agent-config` #905 | FatNine | **lead-recorded** `returns/socialware-creator-agent-config.md` (this push) | **stacked** (FatNine omitted the file; lead reconstructed) |
| `agent-console-operate-first-demo` #904 | Claude/dev | `returns/agent-console-operate-first-demo.md` ✅ | **demo supplement to #905** (Allen 2026-06-23: a view-only demo, not a finished agent console; folded under #905, not a standalone track) |
| `world-deploy-e2e-pg` #902 | zylideveloper | `returns/world-deploy-e2e-pg.md` ✅ | **stacked** |

## Next step

`dev-together close` — review/test in order `#912 → #907 → #910 → #905 → #902`,
approve→merge each (lead, `--admin` if `REVIEW_REQUIRED`), decide the `#902`
`b3b23b74` split, and merge to `main`. Decide separately whether `#904`'s demo
merges or stays as evidence under `#905`. **After close: ESR → ezagent rename
cleanup (task #89).**
