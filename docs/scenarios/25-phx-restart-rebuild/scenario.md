# Scenario 25: Phx restart — snapshot rebuild + ExternalMirror

**Category**: 13 — Recovery + boot
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-28 (Phase 1 PR #451 + `snapshot_restart_test.exs`)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Substantial seeded state:
  - 2 workspaces with 5 agents total
  - 3 sessions across workspaces, with members + recent chat history
  - 1 Feishu binding
  - Granted caps for at least 1 non-admin user
- Admin logged in

## Actors

- **Caller**: operator (phx restart trigger)
- **Targets**:
  - `StateRebuilder` (PR #451) — replays EventLog
  - `SnapshotStore` (PR #451) — per-Kind r/w
  - `BootReconciler` (in ExternalMirror) — sweeps bindings
  - Kind-specific `reconcile_after_load/2` callbacks (PR #403)

## Steps

### Pre-restart snapshot

1. Record the OS PIDs of all running PTYs (cc agents, np agents).
2. Take note of the current state of one in-flight conversation in a session.
3. Note the granted caps for the non-admin user.

### Restart

4. `Ctrl+C` `Ctrl+C` in iex; restart with `iex -S mix phx.server`.

### Post-restart verification

5. Watch the phx boot log; verify:
   - Kind workers spawned from `kind_snapshots` rows.
   - `StateRebuilder` replays the EventLog to fill in any post-snapshot events.
   - `BootReconciler` walks `external_mirror_bindings`; spawns workers; subscribes to publishers (scenario 23).
   - Per-Kind `reconcile_after_load/2` reconciles any DB-only state (e.g. session_members union after restore — PR #403 task #34).
6. Verify `/admin` LV mounts; workspace dropdown populated.
7. Verify the non-admin user can still log in + has the same caps.
8. Send a message in one of the restored sessions; verify the agent (cc / curl / echo) responds.
9. Send a Feishu message in the bound chat; verify it routes back into the session.
10. Verify the old PTY OS PIDs are GONE; new OS PIDs are recorded in the pid-files.

## Expected outcomes

- ALL Kinds restored: agents, sessions, workspaces, users, templates, bindings.
- ALL caps preserved: snapshot includes `:identity.caps` (per `cap_action_axis_snapshot_restore_test.exs`).
- ALL bindings re-activate: `ExternalMirrorWorker` re-subscribes (scenario 23).
- No data loss except for ephemeral in-memory state (e.g. transient routing decisions in-flight).

## Failure modes to test

- Corrupted snapshot row: `term_to_binary` decode fails; StateRebuilder logs + falls back to fresh init (Decision #115 — "Q5: added Behavior is Map.merge(fresh, loaded) to preserve new slice fresh init").
- EventLog replay encounters a deleted Kind: skip + log; no boot failure.
- Disk-full when writing post-restart snapshot: Decision #115 — log + telemetry + continue (let-it-crash NOT applied to disk-full).

## Cross-references

- Related PRs:
  - PR #115 (Decision #115) — Snapshot per-Kind real r/w + 5 strategies
  - PR #403 — snapshot reconcile_after_load (task #34)
  - PR #447 — feat(arch-p1b): EventLog + EventSubscriber
  - PR #448 — feat(arch-p1c): SnapshotStore + StateRebuilder
  - PR #449 — feat(arch-p1d): SagaRunner
  - PR #450 — feat(arch-p1a): Cmd, Router, Behavior macro, Kind ext, LegacyAdapter
  - PR #451 — Phase 1 integration
  - PR #420 — ExternalMirrorWorker cold-spawn re-subscribe
- Related SPECs:
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §5 (StateRebuilder, SnapshotStore, EventLog)
- Tests:
  - `apps/ezagent_core/test/integration/snapshot_restart_test.exs` — THE invariant test
  - `apps/ezagent_core/test/integration/cap_action_axis_snapshot_restore_test.exs`
  - `apps/ezagent_core/test/integration/session_survives_restart_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_e2e_test.exs` — cc orchestrator respawn

## Notes

- This is master README §6 priority 2 — snapshot recovery is the safety net for the 22-Behavior Phase 2 migration.
- Per `feedback_completion_requires_invariant_test`, `snapshot_restart_test.exs` is the architectural gate — any regression here blocks Phase 2 PRs.
- The Phase 1 PR #451 deliverables are themselves untested in production restart scenarios; the first real restart with EventLog active is the post-Phase-1-merge smoke.
