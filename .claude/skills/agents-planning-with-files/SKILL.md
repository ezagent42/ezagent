---
name: agents-planning-with-files
description: >-
  Coordinate multi-agent, multi-worktree coding sessions with durable planning
  files so in-flight work survives /clear, crashes, compaction, and dead
  subagents. Reach for it the moment you SPAWN OR COORDINATE SUBAGENTS, split
  work across MULTIPLE GIT WORKTREES, or share one repo with other people or
  agents at once — the distinct value is a coordinator-owned subagents.md
  registry that RECOVERS a subagent that died mid-task, per-worktree file
  isolation, and per-actor section ownership. Also works for plain single-actor
  planning of a long, multi-step task (plan.md / in-progress.md / done.md that
  outlive a context reset) — but that is the secondary case; don't bureaucratize
  a one-liner. Trigger on "coordinate subagents", "parallel worktrees", "recover
  the agent that died", session hand-off, or any long multi-agent build; also
  "plan this out" / "don't lose state" for a real multi-step solo task. Do not
  trigger for single-step edits, quick one- or two-file changes, or one-off
  questions.
---

# agents-planning-with-files

## Why this exists

Your context window is RAM: volatile, limited, wiped by `/clear`, crashes, and
compaction. The filesystem is disk: persistent and unlimited. So anything
important about a coding session gets written to disk, where it survives a
context reset and where a *different* actor (a teammate, a fresh agent, a
recovering coordinator) can pick it up.

This skill maintains four plain-markdown files at the root of your working tree.
They are **gitignored** — working memory, never deliverables. The point is not
paperwork; it is that when the window dies (or a subagent does), the plan, the
live frontier, the finished work, and the running-agent fleet are all still on
disk and re-readable in seconds.

Most planning-file conventions stop there. The reason this one exists is the two
hard cases they ignore, and which this skill makes concrete:

1. **Multiple people and agents on the same repo at once** — without clobbering
   each other's files. See "Multi-actor coordination".
2. **Work spread across multiple git worktrees in parallel** — with one registry
   that tracks subagents *across* worktrees so a coordinator can recover a
   subagent that died mid-task. See "Multi-worktree coordination".

## The four files

All four live at the **root of your current working tree** (the repo root in the
main checkout; the worktree root inside a worktree — see "Where the files live").

| File | Holds | Write pattern |
|---|---|---|
| `plan.md` | The plan: phases/tasks as checkboxes, plus the **resume point**. | Edit when the plan changes or a phase completes (check it off). |
| `in-progress.md` | The **live frontier**: the exact step you're on right now, the file you're editing, the hypothesis you're testing. | Overwrite freely — it is a scratchpad of *now*. This is what recovery reads to learn what was mid-flight. |
| `done.md` | Append-only log of completed work: what + commit sha + timestamp. | **Append only.** Never rewrite or delete entries. |
| `subagents.md` | Live registry of spawned subagents (coordinator-owned). | Row per agentId; the spawner owns status transitions. See "subagents.md". |

Starter templates for all four are in `assets/`. Copy them to your working-tree
root on first use:

```bash
cp .claude/skills/agents-planning-with-files/assets/{plan,in-progress,done,subagents}.md .
```

## When to start

The skill's real value is coordination, so the **headline triggers are the
multi-actor cases.** Reach for it when any of these is true:

- You are about to **spawn or coordinate subagents** → create all four files,
  `subagents.md` included, and read "Coordination" below.
- Work is **split across multiple git worktrees**, or **another actor (person or
  agent) shares the repo** → create all four and read "Coordination" below.

It **also works for** a solo session with no subagents — a genuinely long,
multi-step task where a `/clear` or crash would cost you your place → create
`plan.md`, `in-progress.md`, `done.md` (skip `subagents.md`; there's no fleet).
This is the secondary case, not the lede.

Below that bar, skip the files — **don't bureaucratize a one-liner.** A quick
one- or two-file edit, a single-step change, or a one-off question needs no
planning files; just do the task.

## The loop

Stop at the first rung that applies, act, then continue:

- Starting real work? → create the files (above), write the plan into `plan.md`.
- About to do a thing? → write the current step into `in-progress.md`.
- Learned something that changes the plan? → edit `plan.md`.
- Finished a thing? → append it to `done.md`, and if it closes a phase, check
  the box in `plan.md`.
- Spawned / a subagent finished / a subagent went silent? → update its row in
  `subagents.md` (see lifecycle below).
- Context died, or you're taking over someone's session? → **session catchup**:
  re-read all four files at your root *before doing anything else*. That
  reconstructs plan + live frontier + done log + subagent fleet.
- Every phase checked off and every subagent `done`? → the session is complete.

## Where the files live (the isolation backbone)

Each working directory has its **own** set of the four files at its root. The
main checkout has one set; every git worktree has its own set. Because the files
are gitignored, they are **never committed**, so worktree A's `plan.md` and
worktree B's `plan.md` are physically distinct files that can never merge or
conflict. **Cross-worktree isolation is automatic** — it falls out of "gitignored
+ per-worktree root", not from any locking you have to remember.

That single fact drives the coordination design: the cleanest way for N actors to
not clobber each other is for each to work in **its own worktree**. This repo
already works that way (`.worktrees/` is used heavily), so lean into it.

**What is shared vs what is isolated (the intended model — deliberate, not a
limitation).** In the multi-worktree mode:

- **Isolated, never merged:** each worktree's `plan.md`, `in-progress.md`, and
  `done.md`. They stay local to the worktree that owns them and are *never*
  reconciled, merged, or combined across worktrees. There is no merge step, and
  there is meant to be none.
- **Shared, exactly one artifact:** the coordinator's **single-writer**
  `subagents.md` registry. It is the *only* cross-worktree file — the
  coordinator's fleet view of every subagent. Subagents never write it.

So "shared planning state" means precisely this: the coordinator's **fleet view**
is shared (via one single-writer `subagents.md`); the per-worktree
plan / progress / done are **not**. Per-worktree isolation plus one single-writer
registry is the whole concurrency model — nothing else crosses a worktree
boundary, by design.

## Multi-actor coordination (same repo, concurrently)

**Actor id.** Every actor picks a stable handle, unique among the actors running
right now:
- Humans: your git short name (e.g. `allen`).
- Agents: role + id (e.g. `coordinator`, `impl-k3`, `agent-7fa3`). For a spawned
  subagent, use the agentId the harness assigns.

**Preferred: one worktree per actor.** Then each actor's four files are isolated
by construction (previous section) and there is nothing to coordinate. This is
the default answer — reach for a shared working tree only when you truly must.

**If actors must share one working tree**, partition each file by actor so edits
never collide:
- Give each file per-actor sections headed `## @<actor-id>`.
- **You may edit only your own `## @<actor-id>` section.** Read others' sections;
  never rewrite them. Because ownership is disjoint, concurrent edits don't
  semantically collide even though it's one file.
- `done.md` stays **append-only** for everyone — you add your finished entries,
  you never touch anyone else's.
- `subagents.md` is owned by the spawner (below), keyed by agentId, so its rows
  are already actor-partitioned.

This "section ownership + append-only" rule is the whole merge discipline. It
needs no lock file. (For the rare case where two actors must edit the *same*
section of the *same* file, don't — split into separate worktrees instead; that
is exactly what worktrees are for.)

## Multi-worktree coordination + subagents.md

The hard part the task cares about: a **coordinator** spawns subagents, often
into *different* worktrees (`.worktrees/<name>/`), and needs to track them
*across* those worktrees so it can recover one that dies.

**Ownership split (this is what avoids cross-worktree write contention):**
- The **coordinator owns `subagents.md`** at its own root. Because the
  coordinator is the single spawner, its `subagents.md` is the authoritative
  registry for the whole fleet — one file, one writer.
- Each **subagent owns its local `plan.md` / `in-progress.md` / `done.md`** at
  *its own worktree root*. The coordinator does not write into subagent
  worktrees; subagents do not write into the coordinator's `subagents.md`. No two
  actors ever write the same file.

**The `worktree` column is the cross-worktree link.** Each row records the
absolute path of the worktree that subagent is working in — that is the pointer
recovery walks to find the dead agent's local files.

### subagents.md row + status lifecycle

One row per subagent:

```
| agentId | task | branch | worktree (abs path) | status | started | updated |
```

The spawner drives status — and naming *who* flips the row *when* is the whole
point, because the `stalled` transition is the recovery trigger:

- On spawn → write the row as `running` (fill agentId, task, branch, worktree
  path, started timestamp). At this one moment you may also **seed the
  subagent's execution ledger in its worktree** — create/point its
  `.superpowers/sdd/progress.md` (if it runs SDD) or this skill's
  `in-progress.md`, and tell the subagent to keep it current — so a later
  recovery is guaranteed a frontier to read. This one-time seed at spawn is the
  **only** write the coordinator makes into a subagent's worktree; thereafter the
  coordinator never touches the subagent's local files (the
  no-cross-worktree-write rule — see `references/coordination.md`).
- On the completion notification → flip to `done`, and move the outcome into your
  own `done.md`.
- If the agent **errors or goes silent** (the API-error case this skill is built
  for) → flip to `stalled`. **This is the recovery trigger.** A `stalled` row is
  a promise to yourself that there is in-flight work at a known worktree waiting
  to be recovered.

Status vocabulary: `queued` → `running` → `done` | `stalled` | `abandoned`.

### Recovery (a subagent died mid-task)

The registry exists so that a dead subagent is a recoverable event, not lost
work. Full runbook in `references/coordination.md`; the short version:

1. Read your `subagents.md`.
2. For each row not `done`: `cd` to its `worktree` path.
3. Read that worktree's **execution ledger** — `.superpowers/sdd/progress.md` if
   the subagent runs SDD, else this skill's `in-progress.md` (what it was
   mid-doing) — plus `plan.md` (its plan + resume point) and `done.md` (what it
   already finished).
4. Check git in that worktree — `git -C <worktree> status` and
   `git -C <worktree> log --oneline -5` — to separate committed from uncommitted
   work.
5. Decide: **resume** (re-dispatch a fresh agent into the *same* worktree with the
   recovered context), **harvest** (commit/cherry-pick its partial work), or
   **abandon** (mark the row `abandoned`, clean the worktree).
6. Update the row's status.

## Session catchup (context loss / hand-off)

On any `/clear`, crash, compaction, or when you inherit another actor's session:
**re-read all four files at your root before acting.** If you are a coordinator,
also scan `subagents.md` for any non-`done` row and run the recovery runbook on
it — a subagent may have died while you were away, and its row is the only record
that it existed.

## Relationship to subagent-driven-development

This skill does **not** replace `subagent-driven-development` (SDD) — the two sit
at **different levels** and compose. Keep using SDD where it applies.

- **SDD's `.superpowers/sdd/progress.md` is the within-worktree *execution*
  ledger** — inside one checkout, how far the work there has gotten (which tasks
  are complete, at which commits). It answers "how far along is the work in
  *this* worktree?"
- **This skill's `subagents.md` is the cross-worktree *coordination / fleet*
  layer** — from the coordinator's vantage, how many subagents exist and each
  one's status and worktree. It answers "*which* subagents are in flight, and
  where?"

They stack rather than compete: the fleet registry points *at* the worktrees; an
execution ledger lives *inside* each one. Recovery uses both — `subagents.md`
locates a stalled subagent and its worktree, then you read that worktree's
execution progress: `.superpowers/sdd/progress.md` if the subagent runs SDD,
otherwise this skill's `in-progress.md` (the execution-ledger stand-in for a
subagent not running SDD). Do not swap one skill out for the other.

## Reference

- `references/coordination.md` — the full multi-actor + multi-worktree rules, the
  complete recovery runbook, and worked examples. Read it when coordinating a real
  multi-agent / multi-worktree session.
- `assets/{plan,in-progress,done,subagents}.md` — starter templates to copy to
  your working-tree root.
