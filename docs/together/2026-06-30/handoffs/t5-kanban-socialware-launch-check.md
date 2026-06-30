# Handoff: T5 kanban socialware launch check

> **Date:** 2026-06-30 · **From:** allen · **To:** jjkysy
> **Tracking:** `T5-kanban-socialware-launch-check` · **Base:** `origin/main`
> **Status:** launch-readiness check.

## Mission

Check whether kanban socialware is ready to go online now. Return a launch or
no-launch verdict with exact blockers and smallest required PR slices.

## Required reading

1. #1020 kanban/dev-together PR.
2. `docs/e2e/kanban-pm-flow/`
3. Current socialware docs and #1090 website references to kanban.
4. Skill `ezagent-developer`; `ezagent-socialware` if changing socialware.

## Definition of Done

- [ ] Current kanban socialware launch path is described.
- [ ] Smoke/E2E proof is attached if launchable.
- [ ] If not launchable, exact blockers and smallest PR slices are listed.
- [ ] Verdict is explicit: launch now / do not launch yet.

## Discuss-first

Stop before large #1020 merge-as-is; this task is launch readiness first.

## Merge model

Use branch `verify/kanban-socialware-launch-0630`; return launch-readiness report.
