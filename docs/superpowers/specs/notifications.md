# Notifications SPEC (stable contract)

> **Status**: stable contract. The decisions / OQs / migration plan live in
> the canonical v2 SPEC at
> `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md`
> (locked at PR-N5 close).
>
> This file is the **stable, non-rev-bumping** consumer-facing contract:
> what Behaviors, LVs, plugins, and tests must do to interoperate with the
> notifications system. Updated only when the public surface or invariants
> change.
>
> Bilingual mirror: `notifications.zh_cn.md`.

## §1 Context

### Pre-PR-N1 (legacy producer fan-out)

Each Behavior that produced a notification (Workspace.add_member,
Identity.grant_cap, Chat.join, Lifecycle.terminate, Template.fork, …)
called `Ezagent.Notifications.notify/3` directly with a custom
payload shape; consumers (AdminLive, NotificationsLive) each
`Phoenix.PubSub.subscribe`'d to a producer-specific topic. The
producer ↔ consumer coupling was M:N — adding a new consumer required
touching every producer to add a duplicate subscribe-able stream.

This fan-out pattern violated:

- **P3 (Single source of truth)** — no canonical place to know "what
  notifications does this Kind emit?"
- **P14 (Dispatch is the only path)** — `Notifications.notify/3` was
  a side-channel that bypassed CapBAC + audit + idempotency.
- **P22 (Reliability primitives in core)** — each producer hand-rolled
  its own retention / cursor / fan-out semantics.

### Post-PR-N1 (slice-change chokepoint introduced — coexisting with legacy)

PR-N1/N2/N3 introduced the SliceChange model: slice mutation itself
is the trigger. Every Behavior's `:invoke` returns
`{:ok, new_slice, result}` (or `{:error, _}`). `Kind.Server.
commit_and_notify/3` is the sole site that observes `new_slice !=
old_slice` and emits a slice-change event. Consumers
`Ezagent.SliceChange.subscribe(entity_uri)` to the entity's stream.

**Current state (2026-05-26): coexists with legacy `Notifications.notify/3`.**
Several producers (Workspace.add_member / remove_member at
`apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:94,124`,
Identity.grant_cap at
`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:301`,
Template.fork at `apps/ezagent_domain_chat/lib/ezagent/behavior/template.ex:543`)
still call the legacy `Notifications.notify/3` directly. PR-N5 is the
planned sweep that migrates all remaining callers onto the SliceChange
chokepoint and deletes `Notifications.notify/3` entirely. Until PR-N5
lands, both paths emit notifications — consumers may receive a logical
event via either channel.

The post-N5 endgame is the single chokepoint at `commit_and_notify/3`
— auditable, testable, ungated by consumer presence.

## §2 Goals

1. **Single PubSub topic per entity, not per (producer, consumer) pair.**
   Topic shape: `esr:entity:<self_uri>:slice_changed`. One stream per
   Kind instance, all slice changes flow through it.

2. **Producers ungated by consumer presence.** A Behavior emits whether
   or not anyone is listening. `Phoenix.PubSub.broadcast/3` is a fire-
   and-forget; the topic is the social contract, not a delivery
   guarantee. (Consumer-presence requirements are out of scope —
   durable delivery would belong to a queue layer per §9.)

3. **Consumer LVs subscribe via `Ezagent.SliceChange.subscribe/1`.**
   The wrapper centralizes the topic-shape contract so consumers
   don't hand-construct topic strings (and so the invariant test in
   §8 can grep for direct `PubSub.subscribe` outside the wrapper).

4. **Slice mutation IS the trigger.** Behavior authors NEVER call
   `Notifications.notify/3` directly (PR-N5 invariant deletes the
   legacy function entirely).

5. **Security-minimal envelope.** The broadcast event carries no slice
   content — only metadata (URI / slice_key / cursor / wall-clock /
   `:ok | :error` summary). Subscribers re-fetch via cap-gated read
   if they need slice data.

## §3 Architecture

```
Producer (any Behavior)
    │
    │   Behavior.invoke/4 returns {:ok, new_slice, result}
    ▼
Ezagent.Kind.Runtime.handle_dispatch/4
    │
    │   diff: new_slice != old_slice ?
    ▼
Ezagent.Kind.Server.commit_and_notify/3    ◄── the SINGLE site that
    │                                          observes slice change
    │   1. apply slice
    │   2. Ezagent.Snapshot.maybe_save/4   ◄── persistence FIRST (so
    │                                          a snapshot crash doesn't
    │                                          ghost-notify subscribers
    │                                          on data that never landed
    │                                          — PR-N1 round-2 fix)
    │   3. Ezagent.SliceChange.emit/4      ◄── THEN emit
    ▼
Ezagent.SliceChange.emit/4
    │
    │   build security-minimal envelope (5 keys, no slice content)
    │   bump per-URI cursor (Cursors GenServer)
    │   Phoenix.PubSub.broadcast(esr_pubsub, topic(self_uri), envelope)
    ▼
{:slice_changed, %{uri, slice_key, cursor, event_at, result_summary}}
    │
    ▼
Consumer LV (AdminLive, NotificationsLive, ExternalMirror Worker, …)
    │
    │   mount(_, _, socket): SliceChange.subscribe(entity_uri)
    │   handle_info({:slice_changed, event}, socket):
    │       — if event.slice_key in cares_about, re-fetch via
    │         Ezagent.Kind.get_slice(uri, slice_key) OR
    │         Ezagent.Invocation.dispatch/1 (cap-gated read)
    │       — apply to assigns / push patch / push flash
```

### Persisted intent (LV reconnect)

`Ezagent.NotificationSubscriptions` is a protected ETS registry
(GenServer-owned writes) for persisted subscription intent. A
LiveView crashes / reconnects, but the user's "I am subscribed to
this stream" intent survives across reconnects. The registry
maintains the (entity_uri, stream, ctx) tuple; LV remounts call
`register_subscription/3` to re-bind.

This is the only ETS owner of subscription state — direct
`Phoenix.PubSub.subscribe` from consumer code is the volatile
runtime side; `NotificationSubscriptions` is the durable side.

## §4 Cap model

The cap model splits **producers** from **consumers**:

### Producers — no cap check

Producers don't gate on caller cap. The Behavior whose `:invoke`
mutated the slice has ALREADY been cap-checked at dispatch step 5.5
(`Kind.holds_cap?/2` consulting `Behavior.required_caps/0`). The
slice-change emit is a system-internal observation of "this mutation
happened, with cap checks already passed"; emitting it doesn't need
a second cap.

System principals (`Ezagent.SystemPrincipal.Catalog` — see PR-CC-1
2026-05-25) are the typical "producer" identity for boot-time +
async-replay slice changes; they hold no caps because they're not
dispatching, they're observing.

### Consumers — cap-gated

`Ezagent.Behavior.Notifications` (registered on User Kind):

- **Subject**: `(User|Agent, :subscribe, Ezagent.Behavior.Notifications)`
- **`dispatchable?/0`**: `false` — cap-only, no `:invoke` dispatch
- **Default grant**: every newly-created User receives
  `Notifications.:subscribe` on their own entity URI at registration
  (Identity.create/3 → cap injection)

`SliceChange.subscribe/1` consults this cap at the wrapper boundary:
the caller's URI must hold a `Notifications.:subscribe` cap on the
target entity URI to subscribe. The wrapper raises (let-it-crash)
on cap denial — there's no silent drop of subscription intent.

Cross-workspace subscription is gated by the standard
`:cross_workspace_denied` rules (dispatch step 5.6 / invariant 13);
a non-system-workspace caller subscribing to a different-workspace
entity gets a clean denial.

## §5 Producer list (current, 2026-05-26)

Producers are NOT a hand-maintained list — every Behavior whose
`:invoke` mutates a slice is implicitly a producer. The list below
is informational, for orientation:

| Behavior | Action | Slice mutated | Consumer interest |
|---|---|---|---|
| `Ezagent.Behavior.Workspace` | `:add_member` / `:remove_member` | `workspace_members` | AdminLive / WorkspaceMembersLive |
| `Ezagent.Behavior.WorkspaceUserAdmin` | `:create_user` | `users` (workspace-scoped users index) | AdminLive |
| `Ezagent.Behavior.Identity` | `:grant_cap` / `:revoke_cap` | `caps` | AdminCapsLive |
| `Ezagent.Behavior.UserCredentials` | `:set_password` | `credentials` | (audit-only — UI re-reads) |
| `Ezagent.Behavior.UserTokens` | `:mint` / `:list` / `:revoke` | `tokens` | TokensLive |
| `Ezagent.Behavior.Chat` | `:send` / `:join` | `chat_history` / `chat_members` | ChatLive (real-time scroll) |
| `Ezagent.Kind.Server` | terminate flow | `lifecycle_status` | AdminLive / ObservabilityLive |
| `Ezagent.Behavior.Template` | `:fork` | `template_lineage` (new template URI) | TemplatesLive |
| `Ezagent.Behavior.FeishuUserBinding` | `:bind` / `:unbind` | `feishu_binding` | FeishuBindingsLive |
| `Ezagent.Behavior.FeishuSessionBinding` | `:bind` / `:unbind` | `feishu_session_binding` | FeishuBindingsLive |
| `Ezagent.ExternalMirror.Worker` | (every `:publish`) | publisher slice | DebugPanel (publish health) |

The PR #357 MED batch added Chat.join + Lifecycle.terminate + Template.fork
to the implicit producer set (they were previously calling the legacy
`Notifications.notify/3` — PR-N5 sweep migrated them).

## §6 Consumer LVs

Current consumers (post-PR-N5 audit, 2026-05-26):

| LV | Subscribes to | Slice keys filtered |
|---|---|---|
| `EzagentPluginLiveview.AdminLive` | current user URI + current workspace URI | `caps`, `workspace_members`, `lifecycle_status` |
| `EzagentPluginLiveview.AdminCapsLive` | current user URI (admin self) | `caps` |
| `EzagentPluginLiveview.NotificationsLive` | current user URI | all (filtered by `cares_about` list in mount) |
| `EzagentPluginLiveview.ObservabilityLive` | system workspace URI (admin only) | `lifecycle_status` (cross-tenant audit context) |
| `EzagentPluginLiveview.ChatLive` | current session URI | `chat_history`, `chat_members` |
| `EzagentPluginLiveview.WorkspaceMembersLive` | current workspace URI | `workspace_members` |
| `EzagentPluginLiveview.TokensLive` | current user URI | `tokens` |
| `EzagentPluginLiveview.FeishuBindingsLive` | current user URI + current workspace URI | `feishu_binding`, `feishu_session_binding` |
| `Ezagent.ExternalMirror.Worker` | bound session URI | `chat_history` (event_to_payload → external system) |

`NotificationsLive` is the canonical "notifications drawer" — it
shows the unfiltered slice-change feed for the caller's entity URI
+ workspaces they're a member of.

## §7 Failure modes

### F1 — Producer raises during emit

If `SliceChange.emit/4` raises (e.g. PubSub down, Cursors GenServer
crashed), the wrapper has a `rescue` clause that logs a `Logger.error`
with the producer URI + slice_key + exception and returns `:ok` to
the caller. The slice mutation still landed (it was committed BEFORE
emit per §3 step 2); only the notification was lost. Per
`feedback_let_it_crash_no_workarounds` this is the let-it-crash
tradeoff — we'd rather lose a notification than block the dispatch
on a notification-system fault.

PR #357 codex r1 P27 audit verified the rescue clause is in place +
that `Logger.error` provides enough context to debug "user reports
no notification".

### F2 — Workspace SoT mismatch

If the entity URI's workspace segment doesn't match
`WorkspaceRegistry.lookup(entity_uri)`, `SliceChange.emit/4` is the
authoritative voice — the URI's workspace segment is the SoT (per
SPEC v3 §5.15 + invariant 4). The registry is the cache; emit
proceeds from the URI segment and `workspace_sot` invariant test
fails the build if a producer trips this.

### F3 — Topic-with-no-subscribers

Phoenix.PubSub silently no-ops when broadcasting to a topic with
zero subscribers. This is by design — producers don't gate on
consumer presence (§2). Subscribers that connect later see only
slice-changes after their subscribe point; historical replay is
explicitly out of scope (§9).

### F4 — Cursor regression

`Ezagent.SliceChange.Cursors` is a per-URI monotonic counter
(GenServer-serialized writes). If it regresses (process crash +
restart with old state from snapshot), subscribers MAY see a
duplicate cursor — they should idempotent-process by `(uri, cursor)`.
The invariant test `slice_change_cursor_monotonic_test.exs` exercises
the GenServer with concurrent emits to verify monotonicity under load.

## §8 Invariant tests

### Landed (verified 2026-05-26)

1. **`slice_change_event_carries_no_slice_content_test.exs`**
   (`apps/ezagent_core/test/invariants/`) — the broadcast envelope
   has ONLY the 5 allowed keys (URI / slice_key / cursor / event_at /
   result_summary). Asserts no `old_slice` / `new_slice` / `result` /
   `caller` / `kind_module` leak (PR-N3 codex r2 HIGH-1 fix). This is
   the single landed PR-N invariant gate at the time of writing.

### Planned (PR-N5 sweep targets, not yet landed)

The original v2 SPEC sketched the PR-N5 sweep as 5 grep + behavior
gates. As of 2026-05-26 four of them are still TBD because
`Ezagent.Notifications.notify/3` is **still in use** by several
producers (`apps/ezagent_domain_workspace/lib/ezagent/workspace.ex`,
`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` and
others). The slice-change chokepoint coexists with the legacy
`Notifications.notify/3` path — PR-N5 will collapse them. The
planned invariants are:

2. **`no_direct_notifications_notify_test.exs`** (planned) — grep
   gate: no call to `Ezagent.Notifications.notify/3` outside
   `Ezagent.SliceChange` internals. Will land alongside the PR-N5
   notify/3 deletion sweep.

3. **`no_pubsub_broadcast_to_slice_change_topics_test.exs`** (planned)
   — grep gate: no `Phoenix.PubSub.broadcast` to
   `esr:entity:*:slice_changed` topics outside the
   `Ezagent.SliceChange` module.

4. **`no_pubsub_subscribe_to_slice_change_topics_test.exs`** (planned)
   — grep gate: no `Phoenix.PubSub.subscribe` to slice-change topics
   outside `Ezagent.SliceChange` and `Ezagent.NotificationSubscriptions`.

5. **`every_behavior_mutating_slice_is_producer_test.exs`** (planned)
   — every `Behavior` whose `invoke/4` returns a mutated slice has an
   integration test under `apps/ezagent_*/test/integration/` that
   asserts the slice-change emit (`assert_receive {:slice_changed, _}`).
   This is the architectural-goal invariant per `feedback_completion_
   requires_invariant_test`.

PR-N5 is tracked separately; this SPEC will be updated when the sweep
lands (and the "planned" subsection collapses into the landed list).

## §9 Out-of-scope

- **Cross-workspace fan-out.** Notifications stay within the
  caller's workspace per invariant 13. A cross-workspace observer
  (e.g. system-workspace admin) subscribes via the
  cross_workspace cap; that's covered by §4 + invariant 13, not by
  any cross-workspace fan-out machinery.

- **Durable queue / replay.** Slice-change events are ephemeral —
  if no subscriber was connected at emit time, the event is lost.
  Building a durable queue (offline-user inbox, mobile push when
  app launches) requires a separate Kind (likely Resource-scheme
  `resource://notification_queue/<workspace>/<user>`) with its own
  retention / ack semantics. Out of scope for v1; tracked in
  `docs/futures/todo.md` under "Notification durability".

- **Webhook fan-out to external systems.** Use ExternalMirror Domain
  (invariant 15) — `event_to_payload/1` on an Adapter subscribes to
  the slice-change stream via `Publisher.subscribe_from/3`. Direct
  `Phoenix.PubSub.subscribe` from a binding module is the P11
  violation invariant 16 catches.

- **Multi-region.** Phoenix.PubSub fan-out is single-node by
  default. Multi-region requires `Phoenix.PubSub.Redis` (or similar)
  configuration; the topic shape is unchanged but the SPEC doesn't
  prescribe the transport. Tracked in `docs/futures/todo.md` under
  "Phoenix.PubSub multi-region".

- **Notification deduplication.** A consumer subscribed to overlapping
  entity URIs (e.g. user + workspace) MAY receive duplicate logical
  events. Dedup is the consumer's responsibility (idempotent processing
  by `(uri, cursor)` per §7 F4).

---

## See also

- `apps/ezagent_core/lib/ezagent/slice_change.ex` — emit primitive +
  envelope shape moduledoc
- `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` —
  persisted-intent ETS registry
- `apps/ezagent_core/lib/ezagent/behavior/notifications.ex` —
  cap Behavior on User Kind
- `apps/ezagent_core/lib/ezagent/kind/server.ex` `commit_and_notify/3` —
  the single emit chokepoint
- `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md` —
  canonical v2 SPEC (decisions / OQs / migration). The Allen mental-
  model amendment (chat ≠ notification; notification = same-entity state
  sync across surfaces; ad-hoc notify forbidden) is captured in §2 of
  that doc.
