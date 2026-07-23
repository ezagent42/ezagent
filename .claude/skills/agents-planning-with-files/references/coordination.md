# Coordination: multi-actor + multi-worktree

The full rules for running the four planning files when more than one actor, or
more than one git worktree, is in play. `SKILL.md` has the summary; this file has
the details, the recovery runbook, and worked examples. Read it when you are
actually coordinating a multi-agent / multi-worktree session.

## Contents

- [Model: files are per-working-tree](#model-files-are-per-working-tree)
- [Actor identity](#actor-identity)
- [Rule set A — one worktree per actor (preferred)](#rule-set-a--one-worktree-per-actor-preferred)
- [Rule set B — shared working tree (section ownership)](#rule-set-b--shared-working-tree-section-ownership)
- [subagents.md — the cross-worktree registry](#subagentsmd--the-cross-worktree-registry)
- [Recovery runbook](#recovery-runbook)
- [Worked example: coordinator + 3 subagents in 3 worktrees](#worked-example-coordinator--3-subagents-in-3-worktrees)
- [Anti-patterns](#anti-patterns)

## Model: files are per-working-tree

The four files are gitignored, so they are never committed and never travel
between checkouts. Each working directory — the main checkout and every
`git worktree` — carries its own `plan.md`, `in-progress.md`, `done.md`, and
`subagents.md` at its own root.

Consequence: **two worktrees can never conflict on these files**, because
worktree A's `plan.md` and worktree B's `plan.md` are different inodes that git
ignores in both places. You get isolation for free. The design leans on this:
the primary way to keep N actors from clobbering each other is to give each actor
its own worktree.

In this repo that is already the house style — `.worktrees/` is used heavily, and
`.worktrees/` is itself gitignored, so a subagent's files under
`.worktrees/<name>/{plan,in-progress,done}.md` are covered by that rule. The
coordinator's own files sit at the repo root and are covered by the root-anchored
`.gitignore` entries (`/plan.md`, `/in-progress.md`, `/done.md`, `/subagents.md`).

## Actor identity

Every actor needs a stable handle, unique among actors running concurrently:

- **Humans**: git short name — `allen`, `ruihua`.
- **Coordinator agent**: `coordinator`.
- **Subagents**: the agentId the harness assigns (e.g. `agent-7fa3`), or a role
  handle if you prefer readability (`impl-k3`, `reviewer`). Whatever you choose,
  it must match the `agentId` you record in `subagents.md` so the two line up.

The handle is what namespaces sections (rule set B) and keys registry rows.

## Rule set A — one worktree per actor (preferred)

The default. Each actor works in its own worktree, so each actor's four files are
isolated by construction. Nothing to coordinate on the files themselves.

```bash
# coordinator, from the main checkout, gives each actor its own worktree:
git worktree add .worktrees/impl-feature-x  -b feat/feature-x  origin/main
git worktree add .worktrees/impl-feature-y  -b feat/feature-y  origin/main
```

Each actor copies the templates into its worktree root and works there. The only
shared file is the coordinator's `subagents.md` (below), and only the coordinator
writes it.

## Rule set B — shared working tree (section ownership)

Use only when actors genuinely cannot be separated into worktrees. Partition each
file so no two actors write the same bytes:

- Each file is divided into per-actor sections headed `## @<actor-id>`.
- **You edit only your own `## @<actor-id>` section.** You may read others';
  you never rewrite them. Disjoint ownership means concurrent edits don't
  semantically collide even in one physical file.
- `done.md` is **append-only** for everyone: you add your finished entries under
  your heading; you never touch anyone else's.

Example `plan.md` under rule set B:

```markdown
# Plan

## @coordinator
- [x] Split work into feature-x / feature-y
- [ ] Review + integrate both branches

## @impl-k3
- [x] feature-x: schema
- [ ] feature-x: handler   <- RESUME HERE

## @reviewer
- [ ] awaiting feature-x branch
```

No lock file is needed — ownership is the lock. If two actors ever need to edit
the *same* section of the *same* file, that is the signal to split them into
separate worktrees (rule set A) instead.

## subagents.md — the cross-worktree registry

Owned by the coordinator (the single spawner), at the coordinator's root. It is
the one authoritative view of the whole subagent fleet, spanning every worktree.

Row shape:

```markdown
| agentId | task | branch | worktree | status | started | updated |
|---|---|---|---|---|---|---|
| agent-7fa3 | feature-x handler | feat/feature-x | /Users/you/esr-ng/.worktrees/impl-x | running | 2026-07-23 14:02 | 2026-07-23 14:31 |
```

- **`worktree` is the recovery link** — the absolute path where that subagent's
  local `plan.md` / `in-progress.md` / `done.md` live. Recovery walks it.
- One writer (the coordinator). Subagents never write this file; they write their
  own local files in their own worktree. That split is what removes all
  cross-worktree write contention.

**Layering with subagent-driven-development.** `subagents.md` is the
*coordination / fleet* layer; it does not replace SDD. SDD's
`.superpowers/sdd/progress.md` is the *within-worktree execution* ledger for a
subagent that runs SDD. The two compose — the registry finds the worktree, the
execution ledger (SDD's `progress.md`, or this skill's `in-progress.md` for a
non-SDD subagent) says how far it got. See SKILL.md → "Relationship to
subagent-driven-development".

### Status lifecycle — who flips, and when

| transition | who | when |
|---|---|---|
| (new) → `queued` | coordinator | task decided, not yet dispatched |
| `queued` → `running` | coordinator | at spawn — record agentId, branch, worktree, started |
| `running` → `done` | coordinator | on the completion notification; also append outcome to coordinator's `done.md` |
| `running` → `stalled` | coordinator | agent errored or went silent — **the recovery trigger** |
| any → `abandoned` | coordinator | recovery decided the work is dropped; worktree cleaned |

The `stalled` transition is the reason the file exists. A `stalled` row is a
durable note that in-flight work sits at a known worktree, waiting to be
recovered — even if the coordinator itself gets `/clear`'d before it acts.

**Spawn seed — the one allowed write into a subagent's worktree.** When you flip
a row to `running`, seed that subagent's execution ledger *once*: create/point
its `.superpowers/sdd/progress.md` (if it runs SDD) or `in-progress.md`, and
instruct the subagent to keep it current. This is what guarantees recovery an
execution frontier to read (without it, a `stalled` row could point at an empty
worktree). It is a **one-time** write at spawn and the *only* time the
coordinator writes into a subagent's worktree; after it, the ownership split
holds — the subagent owns its local files, the coordinator owns `subagents.md`.

## Recovery runbook

Run this when a subagent dies mid-task, or on coordinator session catchup when
`subagents.md` has any non-`done` row.

1. **Read the registry.** Open your `subagents.md`. List every row whose status
   is not `done`.
2. **For each such row, go to its worktree.** `cd "<worktree>"` (the path in the
   row). If the path is gone, the worktree was removed — mark the row
   `abandoned` and move on.
3. **Read the local state, in this order:**
   - The subagent's **execution ledger** — `.superpowers/sdd/progress.md` if it
     runs SDD, else `in-progress.md` — the exact step / task frontier it was on
     when it died. This is the highest-value file; it is the live frontier.
   - `plan.md` — the agent's plan and its `RESUME HERE` marker.
   - `done.md` — what it had already finished (don't redo these).
4. **Read the git state** to separate committed from uncommitted work:
   ```bash
   git -C "<worktree>" status
   git -C "<worktree>" log --oneline -5
   git -C "<worktree>" diff --stat
   ```
5. **Decide and act:**
   - **Resume** — re-dispatch a fresh subagent into the *same worktree* with a
     prompt seeded from the recovered `in-progress.md` + `plan.md`. Flip the row
     back to `running` with the new agentId.
   - **Harvest** — the partial work is good; commit or cherry-pick it, append to
     `done.md`, flip the row to `done`.
   - **Abandon** — the work is not worth resuming; flip the row to `abandoned`,
     then `git worktree remove <worktree>` (add `--force` if it has uncommitted
     junk you're intentionally discarding).
6. **Record the transition** in `subagents.md` (`updated` timestamp + new status).

## Worked example: coordinator + 3 subagents in 3 worktrees

Coordinator runs from `/Users/you/esr-ng` (main checkout). It spawns three
implementers, each in its own worktree:

```
/Users/you/esr-ng/subagents.md          <- coordinator-owned registry (all 3 rows)
/Users/you/esr-ng/plan.md,in-progress.md,done.md   <- coordinator's own session

/Users/you/esr-ng/.worktrees/impl-a/{plan,in-progress,done}.md   <- agent-a's local state
/Users/you/esr-ng/.worktrees/impl-b/{plan,in-progress,done}.md   <- agent-b's local state
/Users/you/esr-ng/.worktrees/impl-c/{plan,in-progress,done}.md   <- agent-c's local state
```

Mid-run, `agent-b` dies to an API error. The coordinator:

1. Sees no completion notification; flips `agent-b`'s row to `stalled`.
2. `cd /Users/you/esr-ng/.worktrees/impl-b`.
3. Reads `in-progress.md`: "editing lib/foo/handler.ex, adding the validate/1
   clause; tests not yet run."
4. `git -C ... status`: `handler.ex` modified, uncommitted.
5. Decides **resume**: re-dispatches a fresh agent into `.worktrees/impl-b` with a
   prompt that quotes the recovered `in-progress.md` line and points at
   `plan.md`'s `RESUME HERE`. Flips the row back to `running` with the new
   agentId.

No work was lost, because the dead agent's frontier was on disk in its own
worktree and the registry knew exactly where to look.

## Anti-patterns

- **Committing the planning files.** They are working memory. Committing them
  creates merge conflicts across branches and leaks scratch into history. Keep
  them gitignored.
- **Coordinator writing into a subagent's worktree files** (or vice versa),
  *beyond the one-time execution-ledger seed at spawn.* That single seed write is
  the sole sanctioned exception (see "Spawn seed" above); any write after it
  reintroduces the cross-worktree write contention the ownership split removes.
  Coordinator owns `subagents.md`; each subagent owns its own local three.
- **Rewriting `done.md`.** It is append-only. Rewriting it destroys other actors'
  records and the recovery audit trail.
- **Two actors editing the same section of the same shared file.** Split them into
  separate worktrees instead.
- **Trusting memory over the registry on catchup.** After a context reset, the
  `subagents.md` rows are the only record that a subagent existed. Always re-read
  before assuming the fleet is idle.
