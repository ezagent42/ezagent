---
name: dev-together
description: >-
  The shared daily team-development workflow for the ezagent project. Use
  whenever someone is running, or participating in, the dev-together cycle — a
  lead programmer (human OR agent) and developers (human OR agent) moving work
  through: plan the day's tasks → generate handoffs → accept a handoff and build
  on a per-task branch → return results → stack/order the returns →
  review-test-merge to main → end-of-day retrospective. Trigger on
  `dev-together <cmd>` (init / plan / handoff / dive / return / push / close /
  review) AND on natural phrasings like "kick off the day / split today's tasks
  so the branches don't collide", "generate the handoffs and give me dev
  prompts", "pick up / accept this handoff", "return my finished work to the
  lead", "stack the returned handoffs / what's the merge order", "close out the
  day / merge what's ready after checking the DoD and gates", "end-of-day dev
  review — efficiency, gaps, next-day plan", "is this ready to hand off / what's
  the definition of done", "discuss-first or just build this", "what can we
  defer", or "install the dev-together hooks". This is the GLUE around the mature
  skills (superpowers:brainstorming, superpowers:writing-plans,
  superpowers:executing-plans / subagent-driven-development, codex-rescue review)
  — load it before ANY step so the cadence, roles, the docs/together/<date>/
  artifact layout, the handoff standard (demonstrable-DoD), conflict-avoidance,
  and the per-task-branch merge model are applied consistently. Do NOT trigger
  for unrelated one-off git operations (a bare "git push" or "rebase"), a generic
  code-review of a single PR, closing a GitHub issue, brainstorming non-dev
  content, or handing off a non-engineering ticket — those are near-misses, not
  this workflow.
---

# dev-together

How the ezagent team ships work each day. The lead programmer orchestrates a
**fleet of independent developers — human *and* agents** in parallel; this skill
keeps them aligned, conflict-free, reviewed, and on a daily cadence.

**Reuse, don't reimplement.** dev-together is *glue*. Each step DELEGATES to a
mature skill and only adds the cadence + roles + artifact layout + the handoff
standard + conflict/merge management:
- shape a design → **superpowers:brainstorming**
- break work into steps → **superpowers:writing-plans**
- execute a handoff → **superpowers:executing-plans** / **superpowers:subagent-driven-development**
- adversarial review → **codex-rescue** (static-only, no `mix`)
- project rules → **ezagent-developer**, **ezagent-socialware**, `docs/guide/world-coordination.md`

## Roles
- **Lead programmer** — anyone, human or agent. Plans, generates handoffs, and is
  the **only path to `main`** (via `close`). The lead role is a hat, not a person.
- **Developer** — human or agent. Accepts handoffs, builds on per-task branches,
  returns results.

## Artifacts — `docs/together/YYYY-MM-DD/` (one dated folder per day)
```
docs/together/YYYY-MM-DD/
├── plan.md             # lead (plan):    tasks, scope, per-task branches, conflict map
├── handoffs/<task>.md  # lead (handoff): one reviewed handoff per task
├── returns/<task>.md   # dev  (return):  done + DoD artifact + merge request
├── stack.md            # lead (push):    returns in analyzed merge order
└── review.md           # lead (review):  end-of-day retrospective + next-day suggestions
```
Durable design specs/notes still live in `docs/superpowers/`; `docs/together/` is
the **daily operational record**.

## The daily cycle (8 commands)
Invoke as `dev-together <command> [args]`. **Read the matching step file before
acting** — each says who runs it, which mature skill it delegates to, its inputs,
and its output artifact.

| # | Command | Role | One-liner | Detail |
|---|---------|------|-----------|--------|
| 1 | `init` | dev/lead | install the deadline hook + scaffold today's folder | [commands/init.md](commands/init.md) |
| 2 | `plan` | lead | scope the day's tasks → `plan.md` | [commands/plan.md](commands/plan.md) |
| 3 | `handoff` | lead | generate the day's handoffs in parallel → `handoffs/` + dev prompts | [commands/handoff.md](commands/handoff.md) |
| 4 | `dive <handoff>` | dev | accept a handoff, branch off main, build | [commands/dive.md](commands/dive.md) |
| 5 | `return [branch]` | dev | return results → `returns/<task>.md` | [commands/return.md](commands/return.md) |
| 6 | `push` | lead | stack the returns + analyze merge order → `stack.md` | [commands/push.md](commands/push.md) |
| 7 | `close` | lead | review/test the stack, merge to `main` | [commands/close.md](commands/close.md) |
| 8 | `review` | lead | end-of-day retrospective → `review.md` | [commands/review.md](commands/review.md) |

`brainstorm` is NOT a dev-together command — use **superpowers:brainstorming**
directly inside `plan`/`handoff`.

## The handoff standard
Every handoff is a self-contained spec an unfamiliar dev can run. The load-bearing
rules — **definition of done = a demonstrable artifact**, **discuss-first
triggers**, **defer rules**, **the per-task-branch merge model** — are in
[references/handoff-standard.md](references/handoff-standard.md); the copy-paste
skeleton is in [references/handoff-template.md](references/handoff-template.md).

## Why these rules (adapt, don't obey blindly)
Per-task branches + lead-merges keep parallel devs from colliding and give one
accountable integration point (`push`+`close`). Adversarial review before build
catches *wrong-approach*, not just defects. A demonstrable DoD stops "green tests,
broken product". The deadline + clean-split-on-defer keep the cadence
unblockable. `review` closes the loop daily. If a case isn't covered, reason from
these goals.
