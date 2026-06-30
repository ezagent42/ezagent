# Dev Together Review - 2026-06-29

reviewed_at: 2026-06-30 09:45 +0800
lead: allen / codex
timezone: GMT+8

## 1. Close Summary

The main close result is #1096. The initial branch solved the wrong problem by
adding a core local dispatch bypass. The accepted merge removed that bypass and
fixed the actual AutoService create-time state problem:

- cc orchestrator creation goes through AgentTemplate materialization;
- sandbox config is initialized during Agent Kind create;
- `sandbox.write_path` is now `sandbox.update_config`;
- `TemplateSpawn` skips fallback dispatch when the live sandbox slice already
  matches the returned meta;
- grants stay on the normal `Identity.Grant` + `Invocation.dispatch/1` path.

The merged SHA is `72ae93a381d87943d2d41a04446483c8026fa7b0`.

## 2. What Went Well

- The suspected core leak was caught before merge. Final `origin/main` diff has
  no `apps/ezagent_core/lib/ezagent/invocation.ex` change.
- The fix now matches the architecture: sandbox config is create-time Agent state,
  not an external transport readiness concern.
- Verification used a disposable PostgreSQL Docker container and removed it after
  tests, avoiding both the deprecated sqlite path and the corrupt local PG volume.
- PR comment and PR body now explain the redo, so the contributor has a durable
  record rather than only TUI context.

## 3. Friction / Process Debt

- 2026-06-29 had returns but no `stack.md`, so close had to reconstruct the
  ledger after the fact.
- `team.md` still points several developers at old latest returns. Today's plan
  should cite the newest real return/PR state even if `team.md` is stale, then
  update team state in the next review.
- `2026-W27/weekly-goals.md` was missing. It has now been created by rolling the
  W26 goals forward and adding dev-together self-bootstrapping as an explicit
  weekly goal.
- Local default PG on 55432 is corrupt. The durable rule is now: use temporary PG
  Docker for tests and delete it after the run.

## 4. Carry Forward To 2026-06-30

1. Refresh or close #1095. Its docs still mention the old local-dispatch seam and
   should not be merged as-is after #1096.
2. Rerun `world-host-scope-config-driven` DB-backed gates with temporary PG and
   decide whether to open/merge a PR.
3. Turn #1027 Agent Console QA findings into prioritized bugfix tasks instead of
   leaving the report as an open stale docs PR.
4. Review #1020 as a dedicated kanban/dev-together E2E track. It is too large for
   opportunistic close.
5. Decide #1022 split/close: lockfile sync and personal docs should not remain
   coupled.
