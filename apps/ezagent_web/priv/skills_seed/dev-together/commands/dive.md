# `dev-together dive <handoff>` (dev)

Accept a handoff and build it.

**Delegate to:** **superpowers:writing-plans** (PR-sized breakdown) →
**superpowers:executing-plans** / **superpowers:subagent-driven-development** (TDD
execution) + the handoff's required project skills (**ezagent-developer**, etc.).

**Do:**
1. Read the handoff + every item in its "required reading" (skills + docs, incl.
   `docs/guide/world-coordination.md` if it touches `world`).
2. Create the **task branch off the latest `main`** (the branch named in `plan.md`).
3. Break it into PR-sized steps; confirm scope against `plan.md` + the conflict
   map before building.
4. Implement TDD; **all PRs merge into the task branch — never `main`**; rebase on
   `main` often. Drive toward the handoff's **DoD artifact**.

**Output:** work on the task branch, progressing to the DoD artifact; ready for
`return`.
