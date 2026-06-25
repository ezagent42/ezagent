# `kanban-off-ezagent dive <node>` (contributor)

Claim a board node and build that stage's work. Anyone can claim — including the
leader wearing a contributor hat (see SKILL.md §Roles).

**Delegate to:** **superpowers:writing-plans** (PR-sized breakdown) →
**superpowers:executing-plans** / **superpowers:subagent-driven-development** (TDD
execution) + the handoff's required project skills (**ezagent-developer**, etc.).

**Do:**
1. **`claim_node` on the board** — in `docs/board.md`, set the chosen node's
   `owner:` to yourself and `status: doing`. Per-node `owner_or_admin?` means once
   claimed, only you (or an admin) edit that node. Read the matching handoff in
   `docs/together/<date>/handoffs/` + every item in its "required reading" (skills
   + docs, incl. `docs/guide/world-coordination.md` if it touches `world`).
2. Create the **task branch off the latest `main`** (the branch named in the
   handoff / `plan.md`).
3. Break it into PR-sized steps; confirm scope against `plan.md` + the conflict map
   before building.
4. Implement TDD; **all PRs merge into the task branch — never `main`**; rebase on
   `main` often. Drive toward the node's **DoD artifact** (the board node advanced +
   a demonstrable artifact attached).

**Daily, not per-stage.** A claimed node may stay in its **same stage** for days —
keep `status: doing` and record daily progress on `return`; the stage only advances
when the work completes (recorded by `close`/`review`).

**Output:** work on the task branch, progressing to the node's DoD artifact; ready
for `return`.
