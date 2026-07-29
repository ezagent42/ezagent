---
name: dev-together
description: >-
  Use for the ezagent dev-together daily team workflow: plan tasks, generate
  handoffs, accept/dive into a handoff, return results, stack returned work,
  review-test-merge, close the day, and write retrospectives. Trigger on
  dev-together commands (init, plan, handoff, dive, return, push, close, review,
  audit) and natural requests about daily task splitting, handoffs,
  merge ordering, periodic productization-efficiency audits,
  definition of done, closeout, hooks, or team workflow. Do not trigger for
  unrelated one-off git operations, generic single-PR review, issue closing,
  non-dev brainstorming, or non-engineering handoffs.
---

# dev-together

## Invocation details

Use whenever someone is running, or participating in, the shared ezagent
dev-together cycle: a lead programmer (human or agent) and developers (human or
agent) moving work through plan, handoff, dive, return, stack/order, review,
test, merge to main, and end-of-day retrospective.

Trigger on `dev-together <cmd>`:
- `init`
- `plan`
- `handoff`
- `dive`
- `return`
- `push`
- `close`
- `review`
- `audit` (periodic, not daily)

Also trigger on natural phrasings like:
- "kick off the day / split today's tasks so the branches don't collide"
- "generate the handoffs and give me dev prompts"
- "pick up / accept this handoff"
- "return my finished work to the lead"
- "stack the returned handoffs / what's the merge order"
- "close out the day / merge what's ready after checking the DoD and gates"
- "end-of-day dev review: efficiency, gaps, next-day plan"
- "is this ready to hand off / what's the definition of done"
- "discuss-first or just build this"
- "what can we defer"
- "install the dev-together hooks"

This is the glue around the mature skills (superpowers:brainstorming,
superpowers:writing-plans, superpowers:executing-plans /
subagent-driven-development, codex-rescue review). Load it before any step so
the cadence, roles, `docs/together/<date>/` artifact layout, handoff standard
(demonstrable DoD), conflict avoidance, and per-task-branch merge model are
applied consistently.

Do not trigger for unrelated one-off git operations (a bare "git push" or
"rebase"), generic code review of a single PR, closing a GitHub issue,
brainstorming non-dev content, or handing off a non-engineering ticket. Those
are near-misses, not this workflow.

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

> **Branch model — `main` is trunk; `beta`/`release` are deploy pointers, not task
> branches.** Task branches merge into `main` only. `beta` (smoke) and `release`
> (stable, + `vX.Y.Z` tags) are long-lived **promotion pointers** advanced solely by
> the deploy flow (`git branch -f beta <main-sha> && git push`), never merged into by
> `close`/`push`. The deploy/promotion flow is maintained in a separate private
> repo; see also the guard in [commands/close.md](commands/close.md).

## Artifacts — `docs/together/YYYY-MM-DD/` (one dated folder per day)
```
docs/together/YYYY-MM-DD/
├── board.yaml          # SINGLE SOURCE OF TRUTH — plan writes it (BOD), review updates it (EOD)
├── board.html          # rendered kanban (plan+review 合一); regenerated from board.yaml, never hand-edited
├── tasks/<task>.md     # lead (plan/handoff): ONE FILE PER TASK — the task's full definition
│                       #   AND the dispatch-ready handoff prompt (see below). Supersedes the
│                       #   older `handoffs/` name; treat existing handoffs/ dirs as legacy.
├── returns/<task>.md   # dev  (return):  timestamped done + DoD artifact + merge request
└── stack.md            # lead (push):    returns in analyzed merge order
```

**`tasks/` — one file per task, prompt included (2026-07-29).** Every card on
`board.yaml` MUST have a matching `tasks/<owner>-<slug>.md` containing: the goal,
the acceptance checklist (mirroring the card), dependencies/branch, and — the
point of the file — **the full handoff prompt** a dev or agent can be dispatched
with verbatim. The card carries `task: "tasks/<owner>-<slug>.md"` so board ↔ task
files stay linked. A board built without its tasks/ files is incomplete: the
board is the index, the tasks/ files are the dispatchable substance. When a task
has no formal prompt yet (external-party track, gated work), the file still
exists and says so explicitly — never omit the file.
**`board.yaml` replaces the old plan.md/plan.html/review.md/review.html four-file
model.** It is one living kanban for the day: `plan` writes the cards with their
acceptance checklists into status columns at start-of-day (the board *is* the
plan); `review` moves cards, ticks acceptance with evidence, and fills the
`review:` block at end-of-day (the board *is* the review). Cards left out of the
`done` column are tomorrow's carryover. See `scripts/render/board.example.yaml`
for the annotated schema.
Durable design specs/notes still live in `docs/superpowers/`; `docs/together/` is
the **daily operational record**.

## Durable team state — the inputs `plan`/`handoff`/`review` read

Two durable files outlive the dated daily folders and are the source of truth so
the daily plan is **derived, not guessed**:

- **`docs/together/team.md`** — the roster. **Row identity = `github_username`**;
  carries `role` (`human-dev` | `agent` | `lead`), `short_name` (the alias plans
  cite), `current_track` (what each dev is on now), `latest_return`, `timezone`.
  - `plan` reads it, filters `role: human-dev`, and derives each dev's next
    increment from `current_track` + `latest_return`.
  - `handoff` reads the assignee's row to tailor handoff depth.
  - `review` is the **single writer** of `current_track`/`latest_return` (end of
    day). `return`/`close` never write them. A mid-stream pivot may be reflected
    by the lead.
- **`docs/together/<ISO-week>/weekly-goals.md`** — the week's goals; every daily
  track ladders up to one. `plan` reads it to tag each track with its goal.

**Week-folder naming:** `docs/together/YYYY-Www/` where `YYYY-Www` is the **ISO
week** of the day being planned (ISO weeks start Monday; the year is the
ISO-week-numbering year, which can differ from the calendar year at Jan/Dec
edges). Example: 2026-06-24 (Wed) → `2026-W26`. Compute with
`date -j -f %Y-%m-%d <date> +%G-W%V` (macOS) or `date -d <date> +%G-W%V` (GNU).

## Ledger rules — do not skip these

- **No empty plan.** `plan.md` is invalid until it lists every planned task with
  owner/dev, scope, owned surfaces/files, branch, required reading, conflict
  notes, and handoff order. A placeholder-only plan means the day has not
  started.
- **Timestamp every return.** Each `returns/<task>.md` records `returned_at`,
  `deadline`, and `deadline_status` (`on_time`, `late`, `deferred`, or
  `out_of_scope`). Late returns stay in `returns/` but must be called out by
  `push` and `review` instead of silently counted as planned work.
- **Reconcile the whole ledger.** `push` must account for every file in
  `returns/`: stacked, superseded duplicate, late, out-of-scope, or blocked.
  Nothing may be ignored because it is inconvenient or arrived after deadline.
- **Close PR state.** After `close`, every related GitHub PR is either merged
  through GitHub or explicitly closed/commented as subsumed by the `main` merge
  SHA. Never leave an open PR whose code already landed through the lead path.
- **The board render is deterministic — the model never hand-writes HTML.**
  `plan` and `review` edit **`board.yaml`** (structured card data); the `.html` is
  produced only by
  `uv run --with pyyaml python scripts/render/board2html.py docs/together/<date>/board.yaml`.
  Presentation (kanban skeleton + house-style CSS + the clickable-card JS) lives
  ONLY in `board2html.py`, so every day is byte-identically styled — no visual
  drift, no re-authored `<style>`. Content structure is pinned by the yaml schema
  (`scripts/render/board.example.yaml`); **continuity is pinned in the card
  itself** — a card's `acceptance:` list is written by `plan` (`done: false`) and
  ticked by `review` (`done: true` + `evidence`), and any card not in the `done`
  column is tomorrow's carryover. `board.html` is the team artifact (product-first,
  no Claude↔lead meta); `board.yaml` is the machine/`plan` input. A missing or
  hand-authored `board.html` means the step is incomplete. To change the look,
  edit `board2html.py`, never the daily file. (Requires `uv`; `pyyaml` is fetched
  by `--with`, no repo dep.)
- **Per-card time-boxing & delay-driven decomposition.** Every card carries two
  date fields — **`started`** and **`est_done`** (ISO `YYYY-MM-DD`). A task is
  **sized to ≤1 day**, so a **new** card added to the board defaults to
  `started == est_done == the day it's added` (a same-day estimate). Both fields
  are optional and backward-compatible — a pre-field card renders unchanged.
  - **Delay flag.** The board's *today* is `as_of:` (a top-level field the lead
    sets when organizing the board on a later day; it falls back to the leading
    date of `date:`). A card that is **not `done`** and whose **`est_done` is
    strictly before `as_of`** is marked **延期 (DELAYED)** — `board2html.py`
    renders a red `延期 Nd` rib and surfaces a decomposition hint. Delay is
    computed deterministically from `as_of`, never the wall clock, so a
    re-render is reproducible.
  - **On delay → decompose, then daily-sequence by dependency.** When you
    organize the board on a later day and a task came back DELAYED, **recommend
    splitting it into smaller day-sized sub-modules** and set the sub-modules'
    `started`/`est_done` **one-per-day in dependency order**. Worked example
    (the canonical illustration): task **A** was added 07-24 with
    `started = est_done = 07-24` (a same-day estimate), but actually ran
    07-24→07-26 (3 days). So the **next** time a similarly-sized task **B**
    appears, **pre-decompose** it into **B1 / B2 / B3** with
    `started`/`est_done` = **07-27 / 07-28 / 07-29** respectively — sequential,
    dependency-ordered (`B2` deps B1, `B3` deps B2), one day each. `plan` writes
    these fields; `review` re-estimates on carryover. See the schema at
    `scripts/render/board.example.yaml` (a same-day card, a delayed card, and a
    commented B1/B2/B3 triplet).
- **Efficiency stats are auto-computed with an up/down delta — never hand-typed.**
  `plan` runs `scripts/board_efficiency.py ezagent42/ezagent <prev_date>` (the
  board's yesterday), which measures that day's git-hours lower bound + merged-PR
  count + 折算人月 and each stat's delta vs the day before, and prints an
  `efficiency:`/`efficiency_source:` YAML fragment to splice into `board.yaml`.
  Each `efficiency` entry may carry an optional `delta:` string; `board2html.py`
  renders it as a small colored chip right next to the value — `↓`/`-`/`▼` red
  (down), `↑`/`+`/`▲` green (up), else neutral. Entries with no `delta` render
  exactly as before (backward-compatible). See `scripts/render/board.example.yaml`.
- **Superpowers SDD scratch.** When delegating to
  `superpowers:subagent-driven-development`, use the current Superpowers
  workspace convention: task briefs, reports, review diffs, and progress ledger
  live under the git-ignored `.superpowers/sdd/`, not under `.git/`.

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

**Periodic (not part of the daily cycle):**

| Command | Role | Cadence | One-liner | Detail |
|---------|------|---------|-----------|--------|
| `audit` | lead | monthly / after each big milestone | read-only productization-efficiency checkup, full report delivered out-of-repo to the lead (S0 self-service rate, hub engineering-months, R&D efficiency, investment structure, capacity check; frozen metric definitions so runs stay comparable) | [commands/audit.md](commands/audit.md) |

`brainstorm` is NOT a dev-together command — use **superpowers:brainstorming**
directly inside `plan`/`handoff`.

## The handoff standard
Every handoff is a self-contained spec an unfamiliar dev can run. The load-bearing
rules — the **four-property Definition of Done**, **discuss-first
triggers**, **defer rules**, **the per-task-branch merge model** — are in
[references/handoff-standard.md](references/handoff-standard.md); the copy-paste
skeleton is in [references/handoff-template.md](references/handoff-template.md).

## The full loop (PDCA, completed) — don't let a task come back unfinished/divergent
The 8 commands already form a PDCA loop (`plan`/`handoff` = Plan, `dive`/`return` =
Do, `push`/`close` = Check, `review` = Act). Two phases make it complete so tasks
stop returning **unfinished** or **finished-but-divergent**:
- **Front — clarify/research (the missing "Study").** A build task is never handed
  off while its scope/feasibility/DoD is still unknown. When a **discuss-first
  trigger** fires (the **tiering criterion**), the lead issues a **research handoff**
  (`clarify_first`) first — it produces the **DoD + the build slices**; only then
  the build handoff. No trigger → fast path straight to build. The DoD is often
  *unknowable before research* — research is what writes it.
- **Back — method-writeback (a learning loop, not just a work loop).** The dev
  **captures** at `return` (a per-line **DoD reconciliation** + method-friction);
  the lead **promotes** in `review` (a mandatory **method-deltas** section → a
  dev-together PR or tracked process-debt). The dev never edits the skill (single
  writer); the lead does.
- **Machine return gate.** "Done" is no longer self-asserted: a `return` requires
  **CI (`precommit + check_invariants`) green on the PR head + rebased on `main`**
  (branch-protected). The lead's `close` becomes a confirmation, not the first real
  inspection.

## Why these rules (adapt, don't obey blindly)
Per-task branches + lead-merges keep parallel devs from colliding and give one
accountable integration point (`push`+`close`). Adversarial review before build
catches *wrong-approach*, not just defects. The **clarify/research front-phase**
keeps the lead from handing off a build whose DoD it can't yet write. A
**goal-derived, user-layer, closed-set DoD** + the **machine return gate** stop
"green tests, broken product" and "self-asserted done". **Deferrals are
lead-adjudicated**, never a dev's "READY TO MERGE". `review`'s **method-deltas**
make the loop *learn* (lessons stop recurring). The deadline + clean-split-on-defer
keep the cadence unblockable. If a case isn't covered, reason from these goals.
