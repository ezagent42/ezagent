# Scenario 28: Dispatch audit row (invocations → EventLog)

**Category**: 16 — Audit + observability
**Status**: ⏳ partially-implemented
**Last verified**: 2026-05-28 (EventLog landed PR #447; audit migration is Phase 2)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Some dispatch activity (e.g. scenarios 09 + 14 just ran)
- Admin logged in
- Phase 1 (PR #451) merged: EventLog table exists, EventSubscriber active

## Actors

- **Caller**: any dispatching caller
- **Targets**: `invocations` table (today), `event_log` table (post-Phase-2)

## Steps

### Today (Phase 1)

1. From iex or `/admin/snapshots` LV: query the latest `invocations` rows.
2. Each `Invocation.dispatch/1` writes a row with:
   - `caller_uri`
   - `target_uri`
   - `behavior`
   - `action`
   - `args` (sanitized — no api-keys; PR #389 cleanup)
   - `result` (`:ok` / `:unauthorized` / `:cross_workspace_denied` / etc.)
   - `inserted_at`
3. Telemetry events also fire:
   - `[:ezagent, :authz, :granted]` / `[:ezagent, :authz, :denied]`
   - `[:ezagent, :invocation, :start]` / `[:ezagent, :invocation, :stop]`
4. Verify a denial scenario (scenario 15) writes a `:authz_denied` row.

### Post-Phase-2 (intended)

5. After Phase 2 migrates per-domain Behaviors to the new `action/3` macro, the new `EventLog` becomes the canonical events table.
6. Each effect from `handle_<action>/2` may emit zero or more events to `EventLog`.
7. `StateRebuilder` replays `EventLog` rows on boot (scenario 25) to reconstitute Kind state.
8. `/admin/events` LV (NEW — not yet shipped) queries `EventLog` by aggregate / workspace / time.

### Telemetry dashboard (today)

9. With `:telemetry_metrics` registered, expose to Prometheus / a custom LV dashboard.
10. Track: invocations/sec, authz_denial_rate, average dispatch latency, top-10 callers.

## Expected outcomes

- Today: complete `invocations` audit trail for every dispatch.
- Post-Phase-2: `EventLog` carries replayable events; `invocations` may either remain (compat) or be folded into EventLog.
- No api-key / credential leakage in `args` (post-PR #389 sanitization).

## Failure modes to test

- Audit write fails (disk-full): `Ezagent.Audit` writer logs + emits telemetry; dispatch continues (let-it-crash NOT applied per Decision #115).
- Telemetry handler crashes: detached + logged (Phoenix.LiveDashboard handles this).
- Retention: no automatic retention today; manual SQLite vacuum is the operator option. Production GA needs a retention policy SPEC.

## Cross-references

- Related PRs:
  - PR #447 — feat(arch-p1b): EventLog + EventSubscriber
  - PR #448 — SnapshotStore + StateRebuilder (consumes EventLog)
  - PR #389 — args sanitization (api-keys stripped from invocation args)
- Related SPECs:
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §5 — EventLog as first-class primitive
  - `docs/notes/2026-05-24-notification-log-audit.md` — current state audit
- Tests:
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs` — checks `:authz_denied` audit row
  - Phase 1 PR #447 tests in `feat/p1b-events` sub-branch
- Open bugs / gaps:
  - **`/admin/events` LV does not exist** today.
  - **No retention policy** SPEC.
  - **Phase 2 migration plan** for `invocations` → `EventLog` is the next SPEC (post Phase 1 stabilization).

## Notes

- This scenario tracks the audit evolution from current `invocations` table → SPEC #445's `EventLog`. The two coexist during Phase 2; Phase 3 deletes the old path.
- Per `feedback_completion_requires_invariant_test`, the audit-completeness invariant — "every dispatch ⇒ exactly one events row" — is a Phase 2 architectural gate.
