# Subagents — live registry (coordinator-owned)

<!--
Working memory, gitignored. ONE writer: the coordinator that spawns them.
This is the cross-worktree fleet view and the recovery index. The `worktree`
column is the pointer recovery walks to find a dead agent's local files.

Status lifecycle (coordinator flips):
  queued -> running -> done | stalled | abandoned
  running -> stalled  ==  the RECOVERY TRIGGER (agent errored / went silent)

Recovery: for each non-`done` row, cd to its worktree, read that worktree's
execution ledger (`.superpowers/sdd/progress.md` if it runs SDD, else
in-progress.md) + plan.md + done.md, check `git -C <worktree> status`, then
resume / harvest / abandon. Full runbook: references/coordination.md.
-->

| agentId | task | branch | worktree (abs path) | status | started | updated |
|---|---|---|---|---|---|---|
| <agent-id> | <one-line task> | <branch> | <abs worktree path> | running | <YYYY-MM-DD HH:MM> | <YYYY-MM-DD HH:MM> |
