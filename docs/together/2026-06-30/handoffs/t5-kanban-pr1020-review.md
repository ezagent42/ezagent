# Handoff: T5 #1020 kanban/dev-together review

> **Date:** 2026-06-30 · **From:** allen · **To:** jjkysy
> **Tracking:** `T5-kanban-pr1020-review` · **Base:** `origin/main`
> **Status:** clarify-first — review before build.

## 0. Mission

Review #1020 after the socialware and #1096 changes landed. Produce a concrete
verdict: merge as-is, split into smaller PRs, or close/rebuild. Do not start a
large code rewrite before the review verdict.

## 1. Required reading

1. PR #1020 body and diff.
2. `docs/together/2026-06-29/notes/0629-status-snapshot.md`
3. `docs/e2e/kanban-pm-flow/`
4. `docs/together/2026-06-29/review.md`
5. Skill `ezagent-developer`

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | First phase | Review/test/split verdict only. |
| 2 | Merge-as-is bar | Requires green CI/gates and changed-file risk map. |
| 3 | Large diffs | Prefer split if risk cannot be bounded. |

## 3. Plan

1. Rebase or inspect #1020 against current main.
2. Produce a changed-file risk map.
3. Run the feasible kanban/dev-together gates.
4. Return a verdict with exact next PR slices if split is recommended.

## 4. Definition of Done

- [ ] Changed-file risk map is included.
- [ ] Exact gates run and results are included.
- [ ] Verdict is one of: `merge as-is`, `split`, or `close/rebuild`.
- [ ] If `merge as-is`, CI/gates are green and risks are bounded.
- [ ] If `split`, proposed slices are small enough to hand off independently.

## 5. Discuss-first / defer

Discuss first before merging #1020 as-is or changing dev-together core workflow.
Build work is deferred until the review verdict is accepted.

## 6. Merge model

Use branch `review/kanban-pr1020-post-socialware`. Return review artifact to
lead; no direct main merge.
