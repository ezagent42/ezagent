# dev-together merge stack — 2026-06-23 (lead) · refreshed

_returned handoffs in analyzed merge order · dependencies · conflict check · reconciliation_

> `push` orders + analyzes only; merging happens in `close` (lead → `main`).
> Base `origin/main` at this push = `2d642254` (after the first push #909, email
> #88 PR-1 #906 + PR-2 #908, and team-directory docs merges earlier today).
> **All four planned tasks have now returned** — this refresh supersedes the first
> push (which stacked only #907 + #902 with the other two "in progress").

## Returns analyzed (4 stacked — full plan returned)

| # | Task | Dev | PR | Branch | mergeable | DoD / evidence | returned | status |
|---|---|---|---|---|---|---|---|---|
| 4 | `agent-flavor-headless-protocol-api` | gagameow | [#907](https://github.com/ezagent42/ezagent/pull/907) | `agent-flavor-headless-protocol-api` | MERGEABLE | cc-headless + codex-remote flavors + protocol-api flavor resolution; **342 tests / 0 failures**; 6-agent E2E + 10 screenshots; return + handoff docs | on_time | ✅ stacked |
| 3 | `world-hello-convergence` | zhaomaota97 (Claude) | [#910](https://github.com/ezagent42/ezagent/pull/910) | `world-hello-convergence` | MERGEABLE | world→hello create / operator live preview / public no-login link (+ **cold-link 400→200 fix** `99b3542e`) / builder narrates+replies as itself; E2E 5–8; return at `returns/world-hello-convergence.md` + PR screenshots | on_time | ✅ stacked |
| 1 | `socialware-creator-agent-config` | FatNine | [#905](https://github.com/ezagent42/ezagent/pull/905) | `socialware-creator-agent-config` | MERGEABLE | world agent create/config/detail adapted to AgentManifest/agent-contract (MVP, **0 core/domain change**); spec PRD + plan + evidence (s01–s04 + demo.mp4/gif) | on_time | ⚠️ stacked — **return file missing** |
| 2 | `world-deploy-e2e-pg` | zylideveloper | [#902](https://github.com/ezagent42/ezagent/pull/902) | `world-deploy-e2e-pg` | UNKNOWN (recompute) | PG runbook rewrite + full E2E support matrix + evidence + **fully root-caused crux** (return §7); return at `returns/world-deploy-e2e-pg.md` | on_time | ✅ stacked |

## Merge order (suggested)

**1. `#907` → 2. `#910` → 3. `#905` → 4. `#902`.**

- **`#907` first** — pure agent/plugin + protocol-api code, disjoint from all world
  surfaces, fully gated (precommit 342/0). Lowest risk.
- **`#910` second** — world hello product code; does **not** touch `world_live.ex`
  (it routes hello creation through `behavior/workspace.ex`), so it's disjoint from
  `#905`/`#902`.
- **`#905` third** — owns the `world_live.ex` agent create/config region (plan's
  serialization owner for world agent config UI).
- **`#902` last** — docs/evidence + the one product commit `b3b23b74` (session-
  template picker, `world_live.ex` + `SessionsTable.tsx`); rebase on `#905` because
  both edit `world_live.ex` (see conflict analysis).

## Conflict analysis

Pairwise file-overlap across the four branches — **one** real cross-branch code
conflict, the rest disjoint:

- **`#905` ∩ `#902` = `apps/.../world_live.ex` (the only code overlap).** `#905`
  edits the agent create/config handlers; `#902`'s `b3b23b74` edits the session-
  template picker render. Same file → whoever lands second rebases. **If the prior
  recommendation to split `b3b23b74` out of `#902` is taken at close, this conflict
  disappears** and `#902` becomes pure docs/evidence.
- **`#910` ∩ {`#905`,`#907`} = ∅ (code).** `#910` touches `Conversation.tsx`,
  `customer_app.js`, `behavior/workspace.ex`, hello `generator.ex`/`turn_driver.ex`,
  `chat_feed_controller.ex`, `customer_controller.ex` — none shared with `#905`
  (`Identities.tsx`/`identity_data.ex`/`world_live.ex`/`vite.config.ts`) or `#907`
  (cc/codex/protocol-api + `workspace/agent_create.ex`).
- **`#907` is disjoint from all world branches** (`agent_create.ex` ≠
  `world_live.ex`; plugin_cc/codex/protocol-api are its own surfaces).
- **Doc-only low-risk overlap:** `#902` re-touches `docs/together/2026-06-23/`
  `plan.md` + the three `handoffs/*` already on `main`; resolve as doc merges at
  close if they diverge. Each PR owns its own `returns/*` file (no overlap there).

All branches are off recent `main` and `#910`/`#905` report `MERGEABLE`
(`#907`/`#902` show `UNKNOWN` = GitHub still recomputing against `2d642254`; re-check
at close). No `world-coordination` cross-branch ownership violation observed.

## Close-time decisions (flag, do not merge here)

- **`#902` product commit `b3b23b74`** (session-template picker) — carried from the
  first push: the return asks the lead to **split/cherry-pick vs keep inline** at
  close. Recommendation unchanged: cherry-pick it onto its own branch/PR so the
  docs/evidence land cleanly, the UI change gets its own review, **and the `#905`∩
  `#902` `world_live.ex` conflict is eliminated**. Note: `#910` already lands the
  *backend* `create session.hello from the New-session form` — the picker (`#902`)
  and the backend (`#910`) are complementary; land them coherently.
- **`#902` root-cause crux is owned by the lead — now in flight.** `create_session`
  synchronously gates 90s on the orchestrator MCP bridge-join → timeout → rollback →
  no-snapshot → `:no_such_actor`. This is being fixed structurally by
  **`fix/session-create-orchestrator-decouple`** (spec rev6, **handed to codex
  2026-06-23**): de-orchestrator-ize (orchestrator → `role` member + provision-on-
  route; readiness gate deleted; readiness contract migrated to `domain_agent`).
  Plus the return's secondary finding: `dispatch_agent_create/2` must `catch :exit`
  so a create timeout doesn't crash the LiveView.
- **`#905` is missing its dev-together return file** —
  `docs/together/2026-06-23/returns/socialware-creator-agent-config.md` is absent
  from the PR (CI advisory `#897` will flag it). The PR itself is complete with spec
  PRD + plan + screenshot/video evidence. **Action: FatNine adds the return file**
  (with `returned_at`/`deadline_status`) before close; stacked on the strength of the
  PR + evidence in the meantime, not blocked.
- **`#907` partial slices (by design, not blockers):** cc-headless is a real
  implementation this round (`cc_headless_bridge_adapter.ex` + handoff
  `cc-headless-real-implementation.md`); codex-remote bridge-auth gate is a pre-
  existing codex issue, not introduced here. DoD met.

## Returned-vs-stacked reconciliation (every return accounted for)

| Task / PR | Owner | Return file | Ledger status |
|---|---|---|---|
| `agent-flavor-headless-protocol-api` #907 | gagameow | `returns/agent-flavor-headless-protocol-api.md` ✅ | **stacked** |
| `world-hello-convergence` #910 | zhaomaota97 (Claude) | `returns/world-hello-convergence.md` ✅ | **stacked** |
| `socialware-creator-agent-config` #905 | FatNine | ❌ **missing** | **stacked (return-file gap — FatNine to add)** |
| `world-deploy-e2e-pg` #902 | zylideveloper | `returns/world-deploy-e2e-pg.md` ✅ | **stacked** |
| `agent-console-operate-first-demo` #904 | — | — | **out-of-scope** — not one of today's four planned tasks (separate Agent Console track); not stacked today |

No return is ignored: all four planned tasks are stacked (one with a flagged
return-file gap); `#904` is explicitly out-of-today's-plan.

## Next step

`dev-together close` — review/test in order `#907 → #910 → #905 → #902`, decide the
`b3b23b74` split (which also clears the `world_live.ex` conflict), confirm `#905`'s
return file landed, and merge the ready stack to `main`. The `#902` create-rollback
crux is being fixed out-of-band by the codex-dispatched
`fix/session-create-orchestrator-decouple` work — independent of merging `#902`'s
docs/evidence.
