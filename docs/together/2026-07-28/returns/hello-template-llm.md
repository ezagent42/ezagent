# Hello Template LLM Return — 2026-07-28 Sync

> **Task:** hello-template-llm
> **Branch:** `codex/hello-template-llm`
> **PR:** [#1576](https://github.com/ezagent42/ezagent/pull/1576)
> **Dev:** Codex
> **returned_at:** 2026-07-28 11:28 +0800
> **deadline:** not recorded (continuation of an existing PR)
> **deadline_status:** not recorded

## Sync summary

The branch is based on `origin/main` at `9a0cc8874`. Its PR remote was behind
the branch history and contained older, equivalent Hello commits, so the PR
head is updated with a lease-protected force push rather than replaying the
newer `main` commits onto the old PR head.

This return includes the current worktree changes that complete the
flavor-agnostic Hello LLM request path, add its bridge and delivery coverage,
and make World LiveView bootstrap asynchronously so a Hello session route is
not blocked by the initial state read.

## DoD reconciliation

No dated handoff or separately closed DoD was present for this continuation.
The following records the delivery scope visible in the branch.

| # | Delivery item | status | proof / follow-up |
|---|---------------|--------|-------------------|
| 1 | Hello accepts registered LLM flavors and passes the selected role flavor into the session template | implemented | `EzagentPluginHello.App` and registration/template tests updated |
| 2 | Hello requests completions through the durable AgentBridge contract and correlates asynchronous replies | implemented | AgentBridge completion tests and Hello orchestration tests updated |
| 3 | World initial mount does not synchronously block on the full caller/session/capability read | implemented | `WorldLive` bootstraps state asynchronously and has route/stream regression coverage |
| 4 | Current worktree changes are formatted, tested, committed, and pushed | committed and pushed; full local gate incomplete | implementation commit `097d9c90a`; see local verification note below |
| 5 | Required PR CI is green | queued | [CI run 30326083150](https://github.com/ezagent42/ezagent/actions/runs/30326083150) for `097d9c90a` was queued when this return was updated |

## Verification and CI

- Local gate: `mix precommit` — attempted. The initial test run could not
  connect to the isolated PostgreSQL port; an isolated instance was then
  started on `127.0.0.1:55432`, but the rerun did not produce a complete test
  result in this environment. CI remains the required verification record.
- PR CI: [run 30326083150](https://github.com/ezagent42/ezagent/actions/runs/30326083150)
  is queued for implementation commit `097d9c90a`. This return-document update
  will create a subsequent PR check; do not treat queued checks as a green gate.
- Prior PR head had a failed deterministic gate; that result belongs to the
  previous remote head and must not be used as evidence for this update.

## Notes

- The branch intentionally retains the existing investigation notes under
  `docs/notes/` about Codex host-credential materialization for follow-up.
- The delivery does not claim that Codex remote PTY login is fixed; that is
  tracked separately in [#1602](https://github.com/ezagent42/ezagent/issues/1602).
