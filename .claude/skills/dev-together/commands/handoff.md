# `dev-together handoff` (lead)

Generate the day's handoffs — **in parallel**, one per task in `plan.md`.

**Delegate to:** **superpowers:brainstorming** (design each task) + **omp codex
review** (static-only adversarial review — see
[../references/codex-review.md](../references/codex-review.md)).

**Do (per task, parallelized — a subagent per task):**
0. **Build vs research (the clarify front-phase, tiering).** First decide: does the
   task hit any **discuss-first trigger**
   ([../references/handoff-standard.md](../references/handoff-standard.md))? If yes,
   the task's scope/feasibility/DoD is **not yet knowable** → issue a **research
   handoff** (`clarify_first`), NOT a build handoff. A research handoff's DoD is its
   *deliverable*: **findings + the proposed build slices + the build DoD**, for the
   lead to ratify. Only after that research `return` lands does the lead issue the
   **build handoff** (now with a goal-derived, enumerable DoD). No trigger fires →
   straight to a build handoff (fast path). This is how the lead avoids handing off
   a build task whose DoD it cannot yet write.
1. **Read the assignee's `team.md` row** (`role` / `current_track` /
   `latest_return`). Use it to **tailor handoff depth** — a dev continuing their
   own track needs less context re-derivation (cite their `latest_return`); a dev
   new to a surface gets more required-reading + a worked example. The handoff
   *standard* ([../references/handoff-standard.md](../references/handoff-standard.md))
   is invariant — only the explanation depth flexes.
2. Brainstorm the design to settle the load-bearing decisions
   (**superpowers:brainstorming**).
3. Author the handoff from [../references/handoff-template.md](../references/handoff-template.md),
   applying [../references/handoff-standard.md](../references/handoff-standard.md)
   (DoD = demonstrable artifact; discuss-first; defer rules; per-task-branch merge).
4. **Adversarial review:** Claude self-review + an **omp codex review** static
   pass ([../references/codex-review.md](../references/codex-review.md)) —
   each told to *attack the design*, not proofread. Incorporate findings; a
   handoff ships only after it survives review.
5. Save to `docs/together/<date>/handoffs/<task>.md` and emit a **paste-ready dev
   prompt** for the lead to dispatch.

**Output:** `docs/together/<date>/handoffs/*.md` + one dev prompt per task.
