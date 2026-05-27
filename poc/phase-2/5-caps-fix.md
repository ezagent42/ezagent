# Phase 2.5 — EntityCapsLive pre-spawn + grant fix (mirrors ezagent#419)

## Result: admin caps page works on fresh dev boots without manual RPC workaround

Empirically verified on `poc/phase-2-caps-fix` (branch off `poc/phase-2-customer-service`),
profile `poc-phase2-capsfix`, port 10125, with a fully cleared profile (no pre-existing
admin Kind alive in `KindRegistry`).

## The diff

`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex`:

1. Added `Ezagent.SpawnRegistry` / `Ezagent.ReadyGate` aliases + two poll constants
   (`@ready_poll_attempts 20`, `@ready_poll_interval_ms 25` → ~500ms ceiling).
2. New private helper `ensure_entity_ready(uri)` — calls
   `SpawnRegistry.spawn(uri)` (idempotent; tolerates `{:error, {:no_spawn_fn, _}}`
   for unit-test contexts), then polls `ReadyGate.status/1` up to ~500ms for the
   target to flip `:ready`. Returns `:ok` / `{:error, reason}`.
3. `do_grant_or_revoke/4` now gates the `Invocation.dispatch` behind
   `ensure_entity_ready`. On spawn / ready failure, surfaces a flash error
   instead of dispatching into the `:no_such_actor` / `:not_ready` window.
4. `load_caps/1` also calls `ensure_entity_ready` before the existing
   `KindRegistry.lookup` branch, so the initial render does not
   short-circuit to `:entity_not_live` for a lazy-spawned admin.

## Strategy chosen: (a) pre-spawn + bounded ReadyGate poll, keep `:call`

Considered:

* (a) Pre-spawn idempotently, then briefly poll `ReadyGate.status/1` (~500ms
  ceiling) before keeping the existing synchronous `:call` dispatch. Operator
  gets the existing per-grant success / failure flash.
* (b) Mirror #419 exactly — pre-spawn + switch dispatch to `:cast` so
  `Ezagent.PendingDelivery` buffers through the not-ready window. Loses the
  per-grant result observation; would need a slice-change PubSub event +
  optimistic "pending" flash to keep UX honest.

**Picked (a).** The CapsLive flash UX is point-in-time ("Granted cap to X"
/ "grant_cap failed: ..."): every other admin action on this page is
synchronous and returns a real result. Switching one button to fire-and-forget
without a PubSub subscription would silently degrade UX. The pre-spawn alone
closes the `:unknown` case from issue #395; the bounded poll closes the
`:not_ready` window between `KindRegistry.put_new` and the User Kind's
`post_init/2` cap reconcile. ~500ms ceiling is well inside the operator's
expected click-to-feedback budget and is bypassed entirely once the Kind is
warm (the first attempt sees `:ready` and returns immediately).

#419's choice of `:cast` is correct for its caller (`Behavior.Workspace.invoke/4`
runs inside dispatch and has no UI to flash; buffering is the cleanest path).
The Behavior + LV chokepoints are structurally different — the fix shape is
the same (pre-spawn before dispatch), the post-spawn dispatch mode is not.

## Acceptance

| Step | Result |
|---|---|
| Fresh `mix phx.server` boot (cleared `~/.ezagent/poc-phase2-capsfix/{db,runtime}`) | ✅ booted |
| `mix ezagent.user.set_password entity://user/system/admin --password test1234` | ✅ password set |
| `POST /login/credentials` (HTML form, no dev bypass) | ✅ 302 → /sessions |
| `GET /identities/users/entity%3A%2F%2Fuser%2Fsystem%2Fadmin/caps` | ✅ 200, "Grant new cap" form rendered, no `entity_not_live` short-circuit |
| Server log: `snapshot.restored` audit for admin URI immediately after caps page hit | ✅ proves lazy spawn fired from `ensure_entity_ready` |
| Server log: `identity.list_caps` invocations return `granted` (not `:no_such_actor` / `:not_ready`) | ✅ |
| Manual admin spawn RPC workaround from issue #395 needed? | ❌ NOT needed |

Pre-existing `entity_caps_live_test.exs` baseline: 3 failures unrelated to this change
(verified by stash-then-run-then-pop: same 3 assertions fail on both `HEAD` and
`HEAD + this diff`). The failing assertions check rendered HTML body fragments
("No caps. Grant one above.") that have evolved with the AppShell wrapper; not
my regression.

## Issue #395 closure

This fix closes the **admin caps page** instance of #395. The root cause
(`Invocation.dispatch/1` returning `:no_such_actor` for never-touched
`entity://` URIs) is **not** fixed centrally — every LV that targets a
specific lazy-spawned Kind still needs the same `ensure_entity_ready`
preamble. The issue's "design question" (dispatch lazy-spawns vs.
caller-pre-spawns) is unresolved upstream; this PR picks "caller pre-spawns"
locally, matching #419's precedent.

**Recommend**: keep #395 open with a comment noting this LV is now covered,
but other LVs targeting non-anchored Kinds (any future entity-specific admin
page) need the same treatment until/unless `dispatch/1` grows lazy-spawn.

## Why this is a generic ezagent fix (not migration-specific)

Per `docs/ezagent-migration/migration-design-constraints.md` §2: this PR
contains zero tenant identifiers, zero migration-specific paths, and zero
references to AutoService. The fix lives in `ezagent_plugin_liveview` (a
plugin layer), uses only `Ezagent.SpawnRegistry` / `Ezagent.ReadyGate` /
`Ezagent.Invocation` (core abstractions), and applies to **any** entity URI
the operator opens the caps page for — admin, regular users, agents. The
fix shape is identical to #419's; it just lands at a different chokepoint.

## Files touched

* `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex`
  (+~70 lines, no other files)
