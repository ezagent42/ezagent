# Close-review finding — #958 Agent Console CRUD (incomplete / divergent)

> **Owner:** fatnine · **PR:** #958 (`feat/agent-console-crud`) · **Status:** OPEN — lead disposition pending @林懿伦

## Expected (the goal behind #84)
An **Agent Console**: the operator can create / view / **configure every
agent-config field** / delete agents **from the world UI**, verified end-to-end.

## What's genuinely done (credit)
- Backend CRUD dispatch through the cap-gated `AgentConfig` facade (#938) + #943
  cap-gated reads; create anti-stub; delete-gate (manage-cap + confirm +
  block-while-bound); a real live-status bug fixed. world_live shrunk under the
  1000-LOC cap. Tests exist **at the Invocation/facade seam**.

## Gaps (why it "feels not finished")
1. **The console UI/route has 0 automated tests.** All 5 test files run at the
   backend seam; **none** mount the LiveView or exercise the route (verified: 0
   `live(`/`render_*`/`conn`/`get(` markers). This is why a **config route 404
   slipped through** to manual E2E — fatnine's own return admits a LiveViewTest
   would have caught it. For an operator console, the operator-facing surface is
   unverified by CI.
2. **repoint UI deferred** — backend dispatch wired, no UI. (Part of "configure
   the agent".)
3. **echo agents can't be configured** — blocked on **#918** (echo→`Entity.Agent`
   so it gains `ConfigEvolve`). Today only curl/cc-headless are editable → **not
   "every agent"** yet.
4. **Generic key/value editor**, not structured per-field forms → gap vs "configure
   every field" ergonomically (cf. the goal-ergonomic-verification bar).
5. **Backend auth-ordering info-leak** (admitted, punted to gaga): `delete_path`
   reads the body before the auth gate → a no-cap caller on a *nonexistent* path
   gets `:path_not_found` before `:unauthorized`.
6. Self-declared **"READY TO MERGE"** while deferring #2–#4 — the merge verdict is
   the lead's, not the dev's.

## Verdict
Against the **re-scoped handoff DoD** (update cascade / delete-gate / create /
live-status fix): largely met. Against the **goal** (operator configures every
field, verified through the console): **not done**.

## Lead recommendation (for Allen)
Either **(a)** merge the solid CRUD-backend slice now + open explicit follow-ups
— **minimum: a world LiveViewTest harness covering the console routes** (so the UI
has a gate), plus repoint UI, echo(#918), per-field editor, the delete_path auth
fix; or **(b)** hold #958 until at least the UI-test harness + repoint + echo land.
**Allen to decide.**

→ Process rules that would have caught this: **P2** (goal-derived DoD, not subset),
**P3** (verify at the user-facing layer with a regression test), **P4** (lead
adjudicates deferrals). See `dev-together-process-improvement.md`.
