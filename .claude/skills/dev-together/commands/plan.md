# `dev-together plan` (lead)

Plan and scope the day's tasks so parallel work won't collide.

**Delegate to:** **superpowers:brainstorming** (shape any fuzzy task) →
**superpowers:writing-plans** (break the day's work down).

**Canonical skeleton:** author `plan.md` from
[../references/plan-template.md](../references/plan-template.md) (the §0–§7
section order is fixed so the format stops drifting and `plan.html` mirrors it
1:1). The two load-bearing sections that must never be dropped:

- **§0 本周大局 — STANDING (required in EVERY plan).** The plan MUST open with it,
  carrying three parts: the **week acceptance** (the concrete demo/goal — standing,
  same each day until it lands) + **今日进度** (where we are against that acceptance:
  what landed, what's next, what blocks) + **修正/变化** (deltas vs the last
  plan/state; "无" is valid but must be stated). This is the progress-carrying
  section — never omit it.
- **§5 开工 prompt — one paste-ready block per human dev.** Each block gives the
  branch, scope, required reading (skills + spec/notes), a DoD pointer, the gates
  (`arch.scan + doc.scan + uri_query.scan + check_invariants` / `mix ci.local`),
  and the per-task-branch + "return 前 PR CI 绿 + rebase 到 main" rule. Cross-
  reference the full `handoff` command for tasks that carry real unknowns.

**Do:**
1. Ensure today's folder exists (`scripts/new_day.sh`).
2. **Load the roster — don't guess who the devs are.** Read
   `docs/together/team.md` and **filter to `role: human-dev`**. **Developers are
   ONLY human programmers.** Agents (`role: agent`, e.g. codex/claude) **never
   appear in the plan at all** — no track row AND no "off-plan" section. Agent
   work is coordinated by the lead outside the plan and is not a plan artifact.
3. **Derive each dev's next increment from their state (continuity).** For each
   human dev, read their `current_track` and open their `latest_return` (the path
   in their `team.md` row, or the newest `docs/together/*/returns/*` they own).
   The dev's "today's increment" must be **grounded in that last return** (e.g.
   "re-run the E2E now that #912 landed, verify §7 crux cleared" — derived from
   the return, not invented).
4. **Ladder every track to the week's goal.** Read the current week's
   `docs/together/<ISO-week>/weekly-goals.md` (e.g. `2026-W26/weekly-goals.md`;
   ISO `YYYY-Www` of today) and tag each track with the weekly goal it serves.
5. List the day's tasks. For each: scope, the **surfaces/files it owns**, a
   **per-task branch name**, owner/dev, planned start target, deadline, and
   required reading.
6. Build the **cross-task conflict map** — which tasks touch the same files; for
   anything touching `world`, apply `docs/guide/world-coordination.md` (declare
   surface owners; serialize `styles.css`; respect the layout gate).
7. **Lead-confirmation gate (MANDATORY — do NOT finalize the plan before this).**
   Before writing `plan.md`, send the lead a **per-developer today's task list** —
   one section per human dev, listing that dev's proposed task(s) with a one-line
   scope each (grounded in step 3's continuity + step 4's weekly goal). Wait for
   the lead to **explicitly confirm** (or amend) each dev's list. The lead may
   add, drop, re-scope, or re-assign. Only after the lead confirms do you proceed
   to write `plan.md`. Never auto-finalize a plan the lead has not seen the
   per-dev task lists for.
8. Write `docs/together/<date>/board.yaml`: the **lead-confirmed** day, as
   structured card data (copy `scripts/render/board.example.yaml`, fill it). It is
   the single source of truth for the day. Set the `date`, `north_star`,
   `progress`, `efficiency` (from the latest `pr_session_hours` / audit read),
   `deploy`, `risks`, the `people` swimlanes, and one **card per task** —
   `owner` / `title` / `goal` / `status: planned|wip` / `pr` / `deps` / an
   `acceptance:` list (each `{text, done: false}`) / and the dev's `prompt`. The
   `acceptance` texts are the exact checklist that day's `review` ticks against, so
   make each a decidable success judgement, not a vague aim. **Carry over** every
   unclosed/blocked card from yesterday's `board.yaml` (set `carryover: true`) —
   from the file, not from memory. (Branches + conflict map live in the card
   `branch`/`deps` fields and the handoffs.)
9. **Render (deterministic — never hand-write HTML):**
   `uv run --with pyyaml python scripts/render/board2html.py docs/together/<date>/board.yaml`.
   Presentation lives only in `board2html.py`; a missing/hand-authored
   `board.html` means the step is incomplete.

## Plan completeness gate

Before generating handoffs or accepting returns, verify `plan.md` is not just
the scaffold. Author from
[../references/plan-template.md](../references/plan-template.md); it must include:

- `planned_at`, lead, day deadline, timezone.
- **§0 本周大局 (STANDING)** — the week acceptance + **今日进度** + **修正/变化**.
  A plan that does not open with §0 (all three parts) is invalid.
- **§5 开工 prompt** — one paste-ready kickoff block per human dev (branch, scope,
  required reading, DoD pointer, gates, the per-task-branch / CI-green rule). A
  plan missing the per-dev 开工 prompt is invalid.
- One row per planned task: task id, owner/dev, branch, scope, owned
  surfaces/files, required reading, DoD artifact, deadline.
- A conflict map: shared files/surfaces, serialization owner, and which tasks can
  run in parallel.
- The intended handoff order and which tasks require brainstorming/design
  confirmation before build.
- **Every track maps to a weekly goal; the roster came from `team.md`, not
  memory** (filtered to `role: human-dev`, no agent has a track row), and each
  track cites the dev's `latest_return` as its continuity basis.
- **The lead confirmed the per-dev task lists (step 7) before this plan was
  finalized.** Record `lead_confirmed: true` (+ when) in the plan metadata; a
  plan written without lead confirmation of the per-dev lists is invalid.

If an unplanned return arrives, keep it in `returns/` with
`deadline_status: late` or `out_of_scope`; do not rewrite history by pretending
it was planned.

**Output:** `docs/together/<date>/plan.md` + the set of tasks to hand off.
