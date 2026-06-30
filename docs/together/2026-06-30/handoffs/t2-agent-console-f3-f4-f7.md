# Handoff: T2 Agent Console F3/F4/F7 fixes

> **Date:** 2026-06-30 · **From:** allen · **To:** fatnine
> **Tracking:** `T2-agent-console-f3-f4-f7` · **Base:** `origin/main`
> **Status:** confirmed — convert #1027 QA findings into tested fixes.

## 0. Mission

Turn the highest-value Agent Console QA findings from #1027 into code fixes:
invalid default `advisor` session template must not fail silently, occupied-agent
delete must provide correct feedback, and the session remove/delete path must be
implemented or explicitly split with a tested UX decision.

## 1. Required reading

1. PR #1027 body and files.
2. `docs/together/2026-06-26/agent-console-qa-findings.md`
3. `docs/together/2026-06-29/review.md`
4. `AGENTS.md` Phoenix/LiveView rules.
5. Skill `ezagent-developer`; for LiveView work also follow Phoenix rules.

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | Priority | F3 and F4 must get tests in this slice. |
| 2 | F7 | Implement if local and clear; otherwise split with explicit UX/API decision. |
| 3 | Authority changes | Any CapBAC/session membership change is discuss-first. |

## 3. Plan

1. Reproduce or inspect the #1027 F3/F4/F7 findings.
2. Add failing tests through the real LiveView/web surface where possible.
3. Implement the smallest behavior changes.
4. Run focused tests and relevant invariants.
5. Return PR plus evidence.

## 4. Definition of Done

- [ ] F3 has a regression test proving invalid default `advisor` template does
  not silently fail.
- [ ] F4 has a regression test proving occupied-agent delete reports the right
  outcome.
- [ ] F7 is either implemented with a test or split with a clear decision record.
- [ ] No CapBAC/session authority semantics change without lead confirmation.
- [ ] PR/return includes commands run and screenshots/logs if UI behavior changed.

## 5. Discuss-first / defer

Discuss first for CapBAC, session membership, cross-workspace authority, or any
change that affects more than Agent Console UX. Do not defer F3/F4 tests.

## 6. Merge model

Use branch `fix/agent-console-qa-f3-f4-f7`. Return PR to lead for close.
