# `dev-together handoff` (lead)

Generate the day's handoffs — **in parallel**, one per task in `plan.md`.

**Delegate to:** **superpowers:brainstorming** (design each task) + **codex-rescue**
(static-only adversarial review).

**Do (per task, parallelized — a subagent per task):**
1. Brainstorm the design to settle the load-bearing decisions
   (**superpowers:brainstorming**).
2. Author the handoff from [../references/handoff-template.md](../references/handoff-template.md),
   applying [../references/handoff-standard.md](../references/handoff-standard.md)
   (DoD = demonstrable artifact; discuss-first; defer rules; per-task-branch merge).
3. **Adversarial review:** Claude self-review + a **codex-rescue** static pass —
   each told to *attack the design*, not proofread. Incorporate findings; a
   handoff ships only after it survives review.
4. Save to `docs/together/<date>/handoffs/<task>.md` and emit a **paste-ready dev
   prompt** for the lead to dispatch.

**Output:** `docs/together/<date>/handoffs/*.md` + one dev prompt per task.
