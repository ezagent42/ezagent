> **Task:** gaga — Git Provider V1 Plan B domain spine
> **Branch:** `feat/git-domain-spine`
> **Stacked on:** Plan A PR #1423
> **Dev:** gaga / Codex
> **returned_at:** deferred — WIP skeleton only
> **deadline:** 2026-07-16 23:59 +0800
> **deadline_status:** deferred
> **Status:** WIP — not returned; CI/rebase/PR/merge completion is not claimed

# Return summary

Task 0 documentation freezes the Plan A contract and proposes a narrow reviewed
amendment for five previously undefined provider-neutral types. Production Tasks
1–12 remain deferred. No deployment or merge is authorized.

## DoD reconciliation

| # | DoD line | Status | Proof / open decision |
|---|---|---|---|
| 1 | Track refined Plan B design and executable plan | met for Task 0 | tracked spec/plan files on this branch |
| 2 | Freeze Plan A four structs, five callbacks/actions, and full error union | met for Task 0 | tracked design exact Elixir contracts |
| 3 | Freeze five minimum provider-neutral auxiliary shapes | met for Task 0 | architecture review fixes applied: stored base/head authority, total check normalization, submitted/latest review events |
| 4 | Record exact Tasks 2–3 assertions; keep SSH/merge absent | met for Task 0 | tracked design §13.1 and adapter section |
| 5 | Implement/test the domain spine | deferred | Tasks 1–12 not started |
| 6 | PR-head CI green and rebased on main | deferred | explicitly not claimed by this WIP skeleton |
| 7 | Return/merge/deploy complete | deferred | lead flow and external-state operations not authorized |

## Verification evidence

Task 0 `git diff --check` and targeted contract/exclusion `rg` checks pass. The
stacked Plan A environment probe is recorded as 7 tests, 0 failures; Task 0 itself
adds no runtime code/tests. CI/rebase/return completion remains deferred.

Review-fix verification additionally confirms request-side `base_ref`,
`Review.author`, and review `:pending` are absent, while `allowed_head_ref`, total
check projection, `author_label`, and stable-event dedupe rules are present.

## Deferred boundary

GitHub plugin, credentials/tokens, checkout/worktrees, Kanban, canary, #1360,
AgentRuntime ARB, EntityCaps, bridge join, SSH, merge, production implementation,
CI/rebase/PR return, deployment, and merge remain out of scope.
