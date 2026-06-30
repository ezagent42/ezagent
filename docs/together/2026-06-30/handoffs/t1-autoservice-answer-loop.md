# Handoff: T1 AutoService answer-loop live verify

> **Date:** 2026-06-30 · **From:** allen · **To:** gaga
> **Tracking:** `T1-autoservice-answer-loop` · **Base:** `origin/main`
> **Status:** confirmed — verify the live answer-loop after #1095/#1096.

## 0. Mission

Verify whether AutoService can produce a real cc-authored reply in
`session://autosvc/default/tier1` after #1096 fixed cc orchestrator
materialization. Do not redesign #1096 unless the live evidence contradicts it.

## 1. Required reading

1. `docs/together/2026-06-29/review.md`
2. `docs/together/2026-06-29/stack.md`
3. `docs/together/2026-06-29/returns/autoservice-live-verify.md`
4. `docs/together/2026-06-29/returns/cc-agent-create-failure-resolution.md`
5. Skill `ezagent-developer`
6. `dev-together` handoff/return standard

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | #1096 architecture | Accepted. No `dispatch_registered_local`; sandbox config is create-time agent state. |
| 2 | Success signal | A real agent-authored reply in `session://autosvc/default/tier1` using KB fact `ZEPHYR-7731`. |
| 3 | Test DB | Temporary PostgreSQL Docker only; delete it after the run. |

## 3. Plan

1. Start from fresh `origin/main`.
2. Bring up the AutoService live stack and seed path from the #1095 report.
3. Exercise the real chat/session path until either the cc agent replies or a
   precise Claude auth/bridge blocker is reached.
4. Capture logs/screenshots/transcript and exact commands.
5. Return a verdict: `green` or `blocked`, with the smallest next operational
   step.

## 4. Definition of Done

- [ ] Real channel transcript proves an agent-authored reply, or exact auth/bridge
  blocker evidence is attached.
- [ ] Evidence mentions whether KB fact `ZEPHYR-7731` was retrieved/used.
- [ ] Any DB-backed command used a temporary PG Docker container and includes
  cleanup proof.
- [ ] No new core dispatch/ReadyGate bypass is proposed without evidence that
  #1096 is wrong.
- [ ] Return file records commands, screenshots/logs, verdict, and next step.

## 5. Discuss-first / defer

Discuss first before changing CapBAC, core dispatch, ReadyGate semantics, or
AgentTemplate materialization. Auth/bridge readiness may be returned as blocked
if the evidence is exact.

## 6. Merge model

Use branch `gaga/0630-autoservice-answer-loop`. Return evidence to the lead; do
not merge to main directly.
