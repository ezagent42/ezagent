# Notifications SPEC

This was originally a placeholder requested by the architecture audit
(`docs/notes/2026-05-24-architecture-audit-loc-report.md` LOW item —
"`Ezagent.Notifications` exists only as moduledoc; write a SPEC").

The architecture rev that supersedes the original module-level design
landed concurrently and now serves as the canonical reference:

- **English**: `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md`
- (Chinese mirror to follow per `feedback_bilingual_docs_convention`.)

That document captures Allen's mental-model amendment (chat ≠
notification; notification = same-entity state sync across surfaces;
ad-hoc notify forbidden) + the 5-PR migration plan (PR-N1 SliceChange
hook + NotificationSubscriptions registry → PR-N5 invariant gates).

## What lives in this file going forward

This file holds the **stable, non-rev-bumping** part of the
notification contract:

### Public surface (post-PR-N3)

- `Ezagent.SliceChange.subscribe(uri)` — process subscribes to an
  entity's slice-change stream
- `Ezagent.NotificationSubscriptions.register_subscription(entity,
  stream, ctx)` — persisted intent (survives LV reconnect)
- Message shape: `{:slice_changed, %{self_uri, kind_module, action,
  slice_key, old_slice, new_slice, result, caller, at}}`
- Topic shape: `esr:entity:<self_uri>:slice_changed`

### Invariants (enforced by PR-N5 grep tests)

- No `Phoenix.PubSub.broadcast/3` to `esr:entity:*:slice_changed`
  topics outside `Ezagent.SliceChange`
- No `Phoenix.PubSub.subscribe/2` to those topics outside
  `Ezagent.SliceChange` and `Ezagent.NotificationSubscriptions`
- No `Ezagent.Notifications.notify/3` calls outside the SliceChange
  emit path (PR-N4 sweep target)
- Every `Behavior` that mutates a slice is implicitly a producer
  (no opt-in needed) — verified by the architectural invariant test
  per `feedback_completion_requires_invariant_test`

### Cap model

Per `Ezagent.Behavior.Notifications` registration in
`EzagentCore.Application.register_notifications_behavior/0`:

- Subject: `(User|Agent, :subscribe, Ezagent.Behavior.Notifications)`
- `dispatchable?: false` (cap-only — no `:invoke` dispatch)
- Default grant: a user gets `Notifications.:subscribe` on their own
  URI at registration

### Cross-cutting wiring

- `Kind.Server.commit_and_notify/3` is the SINGLE site where slice
  mutations transition into notifications (post-PR-N1 round-2 fix —
  emit runs AFTER `Snapshot.maybe_save/4` to prevent ghost-notify on
  snapshot failure)
- LV consumers use `Ezagent.SliceChange.subscribe/1` in `mount/3`
  + handle `{:slice_changed, event}` to refresh assigns / push flash

## When to update this file vs the v2 SPEC

- **v2 SPEC** = decisions, OQs, PR sequence, migration. Frozen once
  PR-N5 lands.
- **this file** = contract for ongoing consumers (LV authors, plugin
  authors). Updated when the public surface or invariants change.

## See also

- `apps/ezagent_core/lib/ezagent/slice_change.ex` — emit primitive
- `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` —
  registry
- `apps/ezagent_core/lib/ezagent/behavior/notifications.ex` — cap
  Behavior
- `apps/ezagent_core/lib/ezagent/notifications.ex` — legacy producer
  (will be deleted in PR-N5)
