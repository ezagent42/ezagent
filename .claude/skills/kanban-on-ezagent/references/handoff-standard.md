# The handoff standard (on-ezagent, live-board relay)

Every handoff is a self-contained spec an unfamiliar contributor (**human or agent**)
can execute. It relays **one live board node's** next stage; the requirement is
derived from what that node already carries (its `artifacts` / `metrics`, read via
`get_tree`), not re-authored. Same standard as the off twin — only the board write is
a **dispatch** (`add_node` / `attach_artifact`), not a file edit.

## Definition of Done = a *demonstrable artifact*
"Tests pass" is necessary but **not sufficient**. Every handoff states up-front a
concrete artifact a human can look at:
- **UI / frontend** → an **agent-browser screenshot** of the working surface.
- **Agent / chat / session** → a **success transcript from the real channel** (the
  agent actually replying — not a unit stub).
- **Backend / API** → an **E2E run output** (a request hitting the new path, returning
  the expected shape).
- **Board progression (on-specific)** → the **live node advanced to its target state
  by dispatch** (`set_status`/`set_stage`) **with the artifact attached via
  `attach_artifact`** (PR url / feishu doc / xmind / screenshot / uploaded file) — a
  teammate or agent following the link lands where the work is. The link stored on the
  live node is the same link the off file board would carry (off↔on parity).
- **Always, in addition:** all gates green — `arch.scan`, `doc.scan`, `uri_query.scan`,
  `check_invariants`, `format`, `test`, `:ezagent_plugin_check` — **plus the work's own
  invariant/regression test**.

## Discuss-first triggers
Brainstorm → adversarial review → confirm, **before** building, when any of:
- The approach has **more than one viable option with real trade-offs**.
- It touches **CapBAC/authorization**, **core** (a multi-app change), or a
  **cross-cutting invariant**.
- It **diverges from a north-star** (let-it-crash / no-workarounds, plugin isolation,
  external-integration-is-an-Adapter, no-unowned-caps).
- The design **rests on an unverified assumption** about the codebase.
- It's a **scope / MVP-line** decision.

Otherwise — mechanical implementation inside an approved design, following established
patterns — just build it.

## Defer rules
- **Deferrable only when explicitly flagged with a target** (a later stage / node /
  issue): later-stage breadth, non-load-bearing polish, optional optimizations.
- **Never deferrable:** the **load-bearing design decision**, anything solvable **now
  in the same PR**, **gates/invariants**, **the board write-back dispatch**, and
  **steps that need a human** (flag those; don't silently scope past them).

## Merge model — decentralized relay, centralized merge
Split a node's work into as many PRs as needed; **all PRs merge into the node's own
task branch, never `main`**. Keep the branch **rebased on `main`**. When the DoD is
met, the **leader** merges the task branch → `main` (via `close`) and **dispatches**
the node advance (`set_status`/`set_stage`/`attach_artifact`/`sync_github`). The
leader is the only path to `main`; everything before it (claim, build, relay the next
stage) is peer-to-peer dispatch — and any of those peers may be an agent (see
[agent-orchestration.md](agent-orchestration.md)).

## Required-reading every handoff lists
- Skill **ezagent-developer** (always) + others as relevant (**ezagent-socialware**,
  **ezagent-session-orchestrator**).
- `docs/guide/world-coordination.md` — REQUIRED if the node touches `world`.
- The **kanban-on-ezagent** skill (this workflow + standard) +
  [live-board-access.md](live-board-access.md) (how to read/write the live board by
  dispatch + the node model the handoff relays).
- The live board node's own artifacts (the requirement source, read via `get_tree`) +
  any design spec / research note the work builds on (by path).
