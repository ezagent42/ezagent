# The handoff standard

Every handoff is a self-contained spec an unfamiliar developer (human or agent)
can execute. Copy-paste skeleton: [handoff-template.md](handoff-template.md).

## Definition of Done = a *demonstrable artifact*
"Tests pass" is necessary but **not sufficient**. Every handoff states up-front a
concrete artifact a human can look at:
- **UI / frontend** → an **agent-browser screenshot** of the working surface.
- **Agent / chat / session** → a **success transcript from the real channel**
  (the agent actually replying — not a unit stub).
- **Backend / API** → an **E2E run output** (a request hitting the new path,
  returning the expected shape).
- **Demo-type** (design confirmation) → the **demo merged + viewable on Tailnet**
  + design sign-off.
- **Always, in addition:** all gates green — `arch.scan`, `doc.scan`,
  `uri_query.scan`, `check_invariants`, `format`, `test`, `:ezagent_plugin_check`
  — **plus the work's own invariant/regression test**.

## Discuss-first triggers
Brainstorm → adversarial review → lead confirm, **before** building, when any of:
- The approach has **more than one viable option with real trade-offs**.
- It touches **CapBAC/authorization**, **core** (a multi-app change), or a
  **cross-cutting invariant**.
- It **diverges from a north-star** (let-it-crash / no-workarounds, plugin
  isolation, external-integration-is-an-Adapter, no-unowned-caps).
- The design **rests on an unverified assumption** about the codebase.
- It's a **scope / MVP-line** decision.

Otherwise — mechanical implementation inside an approved design, following
established patterns — just build it.

## Defer rules
- **Deferrable only when explicitly flagged with a target** (a later phase /
  issue): later-phase breadth (token-level streaming, advanced editors),
  non-load-bearing polish, optional optimizations.
- **Never deferrable:** the **load-bearing design decision**, anything solvable
  **now in the same PR**, **gates/invariants**, and **steps that need a human**
  (flag those; don't silently scope past them).

## Merge model
Split a task into as many PRs as needed; **all PRs merge into the task's own
branch, never `main`**. Keep the branch **rebased on `main`**. When the DoD is
met, the **lead** merges the task branch → `main` (via `close`). The lead is the
only path to `main`.

## Required-reading every handoff lists
- Skill **ezagent-developer** (always) + others as relevant (**ezagent-socialware**,
  **ezagent-session-orchestrator**).
- `docs/guide/world-coordination.md` — REQUIRED if the task touches `world`.
- The **dev-together** skill (this workflow + standard).
- The design spec / research note the work builds on (by path).
