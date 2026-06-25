# `kanban-on-ezagent close` (leader only)

Process the merge stack: review/test each entry, merge to `main`, then **dispatch to
advance the live board node**. **This is the ONLY path to `main`** — the single
centralized gate over an otherwise decentralized relay (see SKILL.md §Roles).

**Do:** for each entry in `docs/together/<date>/stack.md`, in the analyzed order:
1. Confirm `stack.md` has reconciled every file in `returns/` and each entry names
   its live board node id. Stop if any return is missing from the reconciliation
   table, lacks a status, or lacks a board node id.
2. Verify the **DoD artifact** is present and **all gates are green** on the task
   branch (`arch.scan` / `doc.scan` / `uri_query.scan` / `check_invariants` /
   `format` / `test` / `:ezagent_plugin_check` + the work's own invariant test).
3. (Re)review/test as the analysis flags (e.g. world overlaps, cross-branch
   conflicts).
4. Rebase the task branch on `main` if needed.
5. Invoke **superpowers:finishing-a-development-branch** for the actual integration
   choice (local merge to `main`, push/create PR, keep as-is, or discard). For
   kanban-on close, the normal leader choice is local merge to `main` after gates
   pass, but use the finishing skill so test verification, worktree detection,
   merge/PR mechanics, and cleanup stay standardized.
6. Run the **PR closure loop** below.
7. **Advance the live board node by dispatch** (mode: :call, leader ctx):
   - `set_status` → `%{id, status: "done"}` (`kanban.ex:496-510`);
   - `set_stage` → `%{id, stage: "<next>"}` **only if the work completed this stage**
     — the Kind enforces 相邻棒推进 (`stage_fits?`, `kanban.ex:439-462`), so an illegal
     advance is rejected at dispatch;
   - `attach_artifact` → the merged artifact link (`%{id, artifact: %{tool:"github",
     kind:"pr", ref:"#NN", url:…}}`, `kanban.ex:517-518`);
   - `sync_github` → `%{id}` to mirror the node as a GitHub issue + re-attach
     (`kanban.ex:169`/`:656`), and/or `register_pr`/`sync_prs` to track PR state.
   ([../references/live-board-access.md](../references/live-board-access.md) §24-action.)
   Record the outcome (merged sha / blocked + reason + PR state) back in `stack.md`.

Stop and surface any entry whose DoD or gates aren't satisfied — don't merge it.

## PR closure loop

For every stacked or subsumed return, after
**superpowers:finishing-a-development-branch** completes, identify linked GitHub PRs
from the return metadata, branch name, and `gh pr list --head <branch> --state all`.

- If the task merged through GitHub, record the merged PR number and merge SHA.
- If the leader merged locally/squashed/cherry-picked into `main`, comment on the
  original PR with the `main` SHA that subsumed it, then `gh pr close` it.
- If the PR remains open intentionally, record the reason and owner in `stack.md`;
  open-by-accident is not allowed.
- If a branch had no PR, record `PR: none` explicitly.

Never leave an open GitHub PR whose code already landed through the leader path.
`sync_prs` (`kanban.ex:201`/`:668`) can poll registered PRs and auto-advance any
merged/closed node to `status: done` — run it to keep the live board honest with
GitHub.

**Output:** merged task branches on `main` + the live board node advanced by dispatch
(`set_status`/`set_stage`/`attach_artifact`/`sync_github`) + updated `stack.md` with
outcomes.
