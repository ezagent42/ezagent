# `dev-together plan` (lead)

Plan and scope the day's tasks so parallel work won't collide.

**Delegate to:** **superpowers:brainstorming** (shape any fuzzy task) →
**superpowers:writing-plans** (break the day's work down).

**Do:**
1. Ensure today's folder exists (`scripts/new_day.sh`).
2. List the day's tasks. For each: scope, the **surfaces/files it owns**, a
   **per-task branch name**, owner/dev, planned start target, deadline, and
   required reading.
3. Build the **cross-task conflict map** — which tasks touch the same files; for
   anything touching `world`, apply `docs/guide/world-coordination.md` (declare
   surface owners; serialize `styles.css`; respect the layout gate).
4. Write `docs/together/<date>/plan.md`: the task list + scope + branches +
   conflict map + the intended `handoff` order.

## Plan completeness gate

Before generating handoffs or accepting returns, verify `plan.md` is not just
the scaffold. It must include:

- `planned_at`, lead, day deadline, timezone.
- One row per planned task: task id, owner/dev, branch, scope, owned
  surfaces/files, required reading, DoD artifact, deadline.
- A conflict map: shared files/surfaces, serialization owner, and which tasks can
  run in parallel.
- The intended handoff order and which tasks require brainstorming/design
  confirmation before build.

If an unplanned return arrives, keep it in `returns/` with
`deadline_status: late` or `out_of_scope`; do not rewrite history by pretending
it was planned.

**Output:** `docs/together/<date>/plan.md` + the set of tasks to hand off.
