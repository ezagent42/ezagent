# `dev-together close` (lead)

Process the merge stack: review/test each entry, then merge to `main`. **This is
the only path to `main`.**

**Do:** for each entry in `docs/together/<date>/stack.md`, in the analyzed order:
1. Verify the **DoD artifact** is present and **all gates are green** on the task
   branch (`arch.scan` / `doc.scan` / `uri_query.scan` / `check_invariants` /
   `format` / `test` / `:ezagent_plugin_check` + the work's own invariant test).
2. (Re)review/test as the analysis flags (e.g. world overlaps, cross-branch
   conflicts).
3. Rebase the task branch on `main` if needed, then **merge → `main`**.
4. Record the outcome (merged sha / blocked + reason) back in `stack.md`.

Stop and surface any entry whose DoD or gates aren't satisfied — don't merge it.

**Output:** merged task branches on `main` + updated `stack.md` with outcomes.
