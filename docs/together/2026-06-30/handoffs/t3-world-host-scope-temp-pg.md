# Handoff: T3 world-host-scope temp-PG verification

> **Date:** 2026-06-30 · **From:** allen · **To:** zyli
> **Tracking:** `T3-world-host-scope-verify` · **Base:** `origin/main`
> **Status:** confirmed — rerun DB-backed gates with temporary PostgreSQL.

## 0. Mission

Rerun the deferred DB-backed gates from `world-host-scope-config-driven` using a
temporary PostgreSQL Docker container. Decide whether the line is ready for a PR,
needs a fix, or should stay deferred with exact evidence.

## 1. Required reading

1. `docs/together/2026-06-29/returns/world-host-scope-config-driven.md`
2. `docs/together/2026-06-29/stack.md`
3. `docs/guide/world-coordination.md`
4. Skill `ezagent-developer`
5. `dev-together` return standard

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | DB | Temporary PostgreSQL Docker only; delete it after verification. |
| 2 | Scope | Verification first. Do not mix broad World UI/style changes into this task. |
| 3 | Output | Merge recommendation based on exact gates, not environment guesses. |

## 3. Plan

1. Start a temporary PG Docker container on a free port.
2. Run the DB-backed gates listed in the return.
3. If green, open/refresh a PR with the minimal world-host-scope change.
4. If red, capture exact failing command/output and recommend the fix.
5. Stop/remove the PG container and record cleanup proof.

## 4. Definition of Done

- [ ] DB-backed gate commands and results are recorded.
- [ ] Temporary PG cleanup proof is recorded.
- [ ] Verdict is one of: `open/refresh PR`, `fix needed`, or `defer`, with reason.
- [ ] No operator World routing/style change is made outside this verification
  scope without coordination.

## 5. Discuss-first / defer

Discuss first before touching shared World routing, socialware external routes,
or shared world styles. A red DB gate can be deferred only with exact failing
evidence.

## 6. Merge model

Use branch `verify/world-host-scope-temp-pg`. Return evidence and recommendation
to lead.
