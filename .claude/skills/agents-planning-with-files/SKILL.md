---
name: agents-planning-with-files
description: >-
  Persist a coding session's state in four gitignored root-level planning files
  (plan.md, in-progress.md, done.md, subagents.md) so work survives /clear,
  crashes, compaction, and dead subagents. Use whenever a task needs 3+ steps or
  5+ tool calls, whenever you spawn or coordinate subagents, whenever multiple
  people or agents work the same repo concurrently, and whenever work is split
  across multiple git worktrees. The value-add over ad-hoc notes: concrete
  multi-actor coordination (per-actor section ownership, append-only merge
  discipline), per-worktree file isolation, and a subagents.md registry that
  lets a coordinator RECOVER in-flight work when a subagent dies mid-task.
  Trigger on "plan this out", "track progress", "coordinate subagents",
  "parallel worktrees", "don't lose state", "recover the agent that died",
  session hand-off, or any long multi-agent build. Do not trigger for
  single-step edits or one-off questions.
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

Don't bureaucratize a one-liner. Create the files at the first rung that applies:

- The task needs **3+ steps or 5+ tool calls** → create `plan.md`, `in-progress.md`, `done.md`.
- You are about to **spawn a subagent** (any) → also create `subagents.md`.
- You are **coordinating across worktrees**, or **another actor shares the repo** → create all four and read "Coordination" below.

Below that threshold, skip the files — just do the task.

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
  path, started timestamp).
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
3. Read that worktree's `in-progress.md` (what it was mid-doing) + `plan.md`
   (its plan + resume point) + `done.md` (what it already finished).
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

## Reference

- `references/coordination.md` — the full multi-actor + multi-worktree rules, the
  complete recovery runbook, and worked examples. Read it when coordinating a real
  multi-agent / multi-worktree session.
- `assets/{plan,in-progress,done,subagents}.md` — starter templates to copy to
  your working-tree root.
