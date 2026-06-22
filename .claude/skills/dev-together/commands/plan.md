# `dev-together plan` (lead)

Plan and scope the day's tasks so parallel work won't collide.

**Delegate to:** **superpowers:brainstorming** (shape any fuzzy task) →
**superpowers:writing-plans** (break the day's work down).

**Do:**
1. Ensure today's folder exists (`scripts/new_day.sh`).
2. List the day's tasks. For each: scope, the **surfaces/files it owns**, a
   **per-task branch name**, and required reading.
3. Build the **cross-task conflict map** — which tasks touch the same files; for
   anything touching `world`, apply `docs/guide/world-coordination.md` (declare
   surface owners; serialize `styles.css`; respect the layout gate).
4. Write `docs/together/<date>/plan.md`: the task list + scope + branches +
   conflict map + the intended `handoff` order.

**Output:** `docs/together/<date>/plan.md` + the set of tasks to hand off.
