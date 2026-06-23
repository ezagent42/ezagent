# `dev-together close` (lead)

Process the merge stack: review/test each entry, then merge to `main`. **This is
the only path to `main`.**

**Do:** for each entry in `docs/together/<date>/stack.md`, in the analyzed order:
1. Confirm `stack.md` has reconciled every file in `returns/`. Stop if any
   return is missing from the reconciliation table or lacks a status.
2. Verify the **DoD artifact** is present and **all gates are green** on the task
   branch (`arch.scan` / `doc.scan` / `uri_query.scan` / `check_invariants` /
   `format` / `test` / `:ezagent_plugin_check` + the work's own invariant test).
3. (Re)review/test as the analysis flags (e.g. world overlaps, cross-branch
   conflicts).
4. Rebase the task branch on `main` if needed.
5. Invoke **superpowers:finishing-a-development-branch** for the actual
   integration choice (local merge to `main`, push/create PR, keep as-is, or
   discard). For dev-together close, the normal lead choice is local merge to
   `main` after gates pass, but use the finishing skill so test verification,
   worktree detection, merge/PR mechanics, and cleanup stay standardized.
6. Run the **PR closure loop** below.
7. Record the outcome (merged sha / blocked + reason + PR state) back in
   `stack.md`.

Stop and surface any entry whose DoD or gates aren't satisfied — don't merge it.

## PR closure loop

For every stacked or subsumed return, after
**superpowers:finishing-a-development-branch** completes, identify linked GitHub
PRs from the return metadata, branch name, and
`gh pr list --head <branch> --state all`.

- If the task merged through GitHub, record the merged PR number and merge SHA.
- If the lead merged locally/squashed/cherry-picked into `main`, comment on the
  original PR with the `main` SHA that subsumed it, then `gh pr close` it.
- If the PR remains open intentionally, record the reason and owner in
  `stack.md`; open-by-accident is not allowed.
- If a branch had no PR, record `PR: none` explicitly.

Never leave an open GitHub PR whose code already landed through the lead path.

**Output:** merged task branches on `main` + updated `stack.md` with outcomes.
