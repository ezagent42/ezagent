# dev-together merge stack — 2026-06-23 (lead)

_returned handoffs in analyzed merge order · dependencies · conflict check · reconciliation_

> `push` orders + analyzes only; merging happens in `close` (lead → `main`).
> Base `origin/main` at push time = `a21cc5ea` (after the email #88 PR-1 #906 +
> PR-2 #908 lead-path merges earlier today). Two of four planned tasks have
> returned; the other two are still in progress (see reconciliation).

## Returns analyzed (2 stacked)

| # | Task | Dev | PR | Branch | DoD | returned | status |
|---|---|---|---|---|---|---|---|
| 4 | `agent-flavor-headless-protocol-api` | gagameow | [#907](https://github.com/ezagent42/ezagent/pull/907) | `agent-flavor-headless-protocol-api` | codex-remote flavor complete + cc-headless spawn-stub (documented unsupported-matrix) + CodexAgent cold-spawn fix + protocol-api flavor resolution; **342 tests / 0 failures**; 6-agent E2E + 10 screenshots; return+handoff docs | on_time | ✅ stacked |
| 2 | `world-deploy-e2e-pg` | zylideveloper | [#902](https://github.com/ezagent42/ezagent/pull/902) | `world-deploy-e2e-pg` | PG runbook rewrite + full E2E support matrix + evidence screenshots + **fully root-caused crux** (return §7); return at [#902 comment](https://github.com/ezagent42/ezagent/pull/902#issuecomment-4778130782) | on_time | ✅ stacked |

## Merge order (no inter-dependency; either order safe)

**Suggested: 1. `#907` → 2. `#902`.**
- `#907` is pure code, fully gated (precommit 342/0) — land first.
- `#902` is docs/evidence + **one product commit** to decide on at close.

## Conflict analysis

`#907` ∩ `#902` = **∅ (clean)**. Disjoint surfaces:
- `#907`: `apps/ezagent_plugin_cc`, `apps/ezagent_plugin_codex`,
  `agent_create.ex`, `agent_flavor_registry.ex`, `apps/ezagent_plugin_protocol_api`,
  `scripts/e2e_init_protocol_api.sh` (agent/backend layer).
- `#902`: `docs/together/2026-06-23/*` + `docs/guide/world-e2e-seed.md` + evidence
  PNGs, **plus one product commit `b3b23b74`** (`world_live.ex` +
  `SessionsTable.tsx`, the session-template picker) riding on the evidence branch.

Both branches are on / rebased onto current `origin/main`; no `world-coordination`
overlap between them.

## Close-time decisions (flag, do not merge here)

- **`#902` product commit `b3b23b74`** (session-template picker) — the return asks
  the lead to **split/cherry-pick vs keep** at close. Recommendation: cherry-pick
  it onto its own branch/PR (it's product code on an evidence task) so the
  docs/evidence land cleanly and the UI change gets its own review; or keep if the
  lead accepts it inline. Decide in `close`.
- **`#902` root-cause crux is owned by the lead** — `create_session` synchronously
  gates 90s on the orchestrator MCP bridge-join → timeout → rollback → no-snapshot
  → `:no_such_actor`. This is being addressed structurally by the
  **`fix/session-create-orchestrator-decouple`** spec (de-orchestrator-ize:
  orchestrator → `role` member + provision-on-route; readiness gate deleted) —
  `docs/superpowers/specs/2026-06-23-session-create-orchestrator-decouple-design.md`.
  Plus the return's secondary finding: `dispatch_agent_create/2` must `catch :exit`
  so a create timeout doesn't crash the LiveView (routed to FatNine).
- **`#907` partial slices (by design, not blockers):** cc-headless is a spawn stub
  (explicit unsupported-matrix; `claude -p` stream-json path researched as
  viable); codex-remote bridge-auth gate is a pre-existing codex issue, not
  introduced here. Both are documented; DoD ("selectable/spawned OR precise
  unsupported matrix") is met.

## Returned-vs-stacked reconciliation (all 4 planned tasks)

| Task | Owner | Return | Ledger status |
|---|---|---|---|
| `agent-flavor-headless-protocol-api` | gagameow | PR #907 (on_time) | **stacked** |
| `world-deploy-e2e-pg` | zylideveloper | PR #902 (on_time) | **stacked** |
| `socialware-creator-agent-config` | FatNine | — | **not yet returned** (in progress; 20:00 deadline). Also inherits a `#902` finding: `dispatch_agent_create` `catch :exit` + empty-CWD silent-fail + detail-page status parse |
| `world-hello-convergence` | zhaomaota97 | — | **not yet returned** (in progress; 20:00 deadline; depends on `#902` support matrix, now available) |

No return file is ignored: both returned tasks are stacked; the two un-returned
tasks are tracked as in-progress against the 20:00 deadline (the 18:00 checkpoint
applies — split + return the smallest demonstrable artifact if they can't finish).

## Next step

`dev-together close` — review/test `#907` then `#902` in order, decide the
`b3b23b74` split, and merge the ready stack to `main`. The two un-returned tasks
either return before close or roll to tomorrow.
