# Scenario 23: ExternalMirrorWorker re-subscribe on cold-spawn

**Category**: 11 — External mirror bindings
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-27 (PR #420 fix for task #49)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Feishu sidecar running
- A binding exists: `{chat_id, app_id} → session://system/feishu-test`
- The corresponding session has been cold-spawned (i.e. not currently in-memory; loaded from snapshot)

## Actors

- **Caller**: BootReconciler at phx startup (or session loader at cold-spawn)
- **Target**: `ExternalMirrorWorker` for the binding

## Steps

### Trigger cold-spawn

1. Stop phx (`Ctrl+C` twice in iex).
2. Verify the OS-level `ExternalMirrorWorker` GenServer is gone (terminated with phx).
3. Restart phx (`iex -S mix phx.server`).
4. BootReconciler runs:
   - Scans `external_mirror_bindings` table.
   - For each row, ensures a worker exists in `WorkerRegistry`.
   - For NEW workers (cold-spawned), calls `Worker.init/1` which:
     - Loads binding data
     - Resolves the bound `session_uri`
     - **Subscribes to that session's publisher PubSub** (THE PR #420 fix)

### Verify

5. Send a message in the bound session.
6. The session publisher emits the event.
7. The cold-spawned worker receives the event (because it subscribed in init).
8. Outbound to Feishu sidecar fires.
9. Verify the message appears in the Feishu chat.

## Expected outcomes

- BootReconciler completes within the phx startup window.
- All bindings have live workers post-boot.
- Cold-spawned workers receive subsequent events from their bound session (no missed events as long as event happens after worker init).

## Failure modes to test

- Binding row in DB but the session has been deleted: BootReconciler should mark the binding as `:orphaned` + log for admin cleanup. (PR #418 partially covers).
- Worker init fails (e.g. session pid not yet available — session loader races BootReconciler): retry with backoff; PR #403 added `reconcile_after_load` to address.
- BootReconciler crash mid-sweep: SagaRunner (PR #449) marks operator-repair (Phase 1 untested at this layer).

## Cross-references

- Related PRs:
  - PR #312 — PR-EM-CORE
  - PR #334 — facade-audit IMPL
  - PR #403 — snapshot reconcile_after_load (DB projection union after restore — task #34)
  - PR #418 — unbind projection sync
  - PR #420 — worker re-subscribes to session publisher on cold-spawn (THE task #49 fix)
- Related SPECs:
  - `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
- Tests:
  - `apps/ezagent_domain_external_mirror/test/ezagent/behavior/external_mirror_reconcile_test.exs`
  - `apps/ezagent_domain_external_mirror/test/invariants/no_pubsub_bypass_in_external_mirror_test.exs`
  - `apps/ezagent_core/test/integration/snapshot_restart_test.exs` (cross-restart invariant)

## Notes

- This was the canonical "register/lookup key parity" lesson (`feedback_register_lookup_key_parity`) at the worker level — when a session re-spawns from snapshot, its publisher subscription must be re-established.
- Per `feedback_north_star_plugin_isolation`, the fix lives in `ExternalMirror` Worker init, not in Feishu plugin code.
