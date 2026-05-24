# Notification Architecture v2 — slice-change as the unit

> Status: SPEC draft for Allen review.
> Methodology: codify Allen 2026-05-24 mental model + plan migration.
> Prior art: `docs/notes/2026-05-24-notification-log-audit.md`, `docs/notes/2026-05-24-notifier-flash-cli-parity-audit.md`.
> Touches: P3 (single source of truth), P6 (completion claim requires invariant test), P11 (plugin external integration = Receiver Kind), P14 (dispatch is the only path), P19 (dispatch hygiene), P22 (reliability primitives).

---

## 0. The model (Allen 2026-05-24)

Allen refined his mental model in four points. They are formalized here as the **authoritative model** that subsequent sections measure code against.

### 0.1 chat ≠ notification

| Aspect | chat | notification |
|---|---|---|
| Semantics | one entity → another entity, with *content* | one entity's own *state/operation* synced across UI surfaces |
| Producer knowledge | **must know the target** (and what to say to it) | **needn't know the subscribers** — they self-serve |
| Direction | outbound (entity-to-entity) | self-emitted (entity-about-self) |
| Cap shape | `<TargetKind>` `:send` cap on the destination entity | none — the affected entity *implicitly* owns its own slice-change stream |
| Failure on no listener | structural error (delivery is the *point*) | silent OK (the *state* changed; UI may catch up later) |

Concrete distinction: when admin Alice sends "hi" to user Bob, that is a **chat** (`Behavior.Chat.invoke(:send, ...)` with `target=session://...`, payload `%Message{...}`). When admin Alice grants user Bob a cap, the resulting "Bob's caps slice changed" event is a **notification** about Bob, even though Bob did not cause it.

### 0.2 root cause vs broadcaster separation

> *A notification's root cause may be ANOTHER entity (admin grants user a cap), but the FINAL notification is fired from the user's OWN registry/slice. Notification ownership = whoever is affected, NOT the actor.*

In other words:

- **Actor** = the principal that invoked the action (`ctx.caller`).
- **Affected entity** = the URI whose slice mutated (`ctx.self_uri` after dispatch).
- **The notification is fired from / scoped to / topic-keyed by the affected entity.**

This is symmetric for self-actions (Bob renames himself → actor == affected) and asymmetric for cross-entity actions (Alice grants Bob a cap → actor != affected). The asymmetric case is exactly where today's ad-hoc producer pattern silently mis-routes notifications: callers may forget which side the notification belongs to.

### 0.3 Notifications should be the DEFAULT BEHAVIOR of slice mutations

> *Any Behavior `:invoke` that mutates a slice should AUTOMATICALLY emit a "slice changed" event to that entity's notification stream. Flash / Feishu / push / etc are just subscribers.*

Operationally:

1. The hook fires inside `Ezagent.Kind.Runtime.handle_dispatch/4` (post-invoke, post-snapshot, pre-telemetry-stop).
2. Comparison `new_slice != old_slice` gates emission (parity with `Ezagent.Kind.Snapshot.maybe_save/4` so we don't fire spuriously).
3. The event is keyed by `ctx.self_uri` (the affected entity), NOT `ctx.caller` (the actor).
4. Subscribers are self-serve: anyone who cares about entity X subscribes to entity X's notification topic.

### 0.4 Forbid ad-hoc notify calls

> *Current `Notifications.notify/3` requires producers to explicitly remember to call — this is the ad-hoc pattern Allen wants to eliminate. Risk: multi-notification bugs, drift, missing notifications when new Behaviors added.*

Concrete failure modes the ad-hoc pattern admits:

| Failure mode | Symptom | Detectable? |
|---|---|---|
| New Behavior added; author forgets to call `notify/3` | UI never updates | Not by any current test |
| Same mutation notified twice (action body + auto-hook) | Duplicate flash / inbox row | Not by any current test |
| Notification fires on validation-rejected mutation (`{:error, ...}`) | False UI state | Not by any current test |
| Notification fires on cap-denied dispatch | Privilege oracle | Not by any current test |
| Notification scoped to actor instead of affected entity | Wrong inbox | Not by any current test |

Per P3 (single source of truth) and P6 (completion claim requires invariant test), the architecture must make the correct path the *only* path, with an invariant test that fails when the structural property is violated.

---

## 1. Current state — what aligns, what doesn't

### 1.1 Aligns ✅

- **`Ezagent.Notifications.topic/1` shape is already keyed by the affected entity** (`esr:user:<uri>:events`). The wire format `{:notification, user_uri, payload}` carries `user_uri` as the *subject*, not the *actor* — model point 0.2 is structurally honored at the envelope layer.
- **System bypass via `ctx.caps == :system`** matches model point 0.2: when one entity's action triggers another entity's notification, the system caller pattern is the right escape hatch (the notification crosses a cap boundary the actor doesn't itself hold).
- **`Ezagent.Behavior.Notifications` is `dispatchable?: false`** — already aligns with the "notifications are not chats" axis (0.1): they aren't a Behavior action you invoke; they're a side-channel emission.
- **`Ezagent.Audit.@events` includes `[:ezagent, :notification, :emit]`** (PR #301). Notifications are visible to the audit pipeline. Model point 0.3 ("flash / Feishu / push / etc are just subscribers") is already true on the *audit* axis — audit subscribes to telemetry, not to the inbox topic, but the cross-reference is wired.
- **`AdminLive.mount/3` subscribes to `Ezagent.Notifications.topic(caller_uri)`** (PR #300). The consumer-side wiring lives; subscribers are real, not just tests.
- **`Ezagent.Kind.Server.handle_call({:ezagent_dispatch, ...})` is the funnel** all dispatched mutations pass through. There is exactly one hook point (`server.ex:124-141` + `:144-164`), per `Ezagent.Kind.Runtime.handle_dispatch/4`. Model point 0.3's "automatic" promise has a concrete place to land.

### 1.2 Doesn't align ❌

- **`Ezagent.Notifications.notify/3` is used as an ad-hoc helper** at 4 producer sites (PR #300):
  - `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:269` — chat receive (the original chat-domain producer, dating from PR-C)
  - `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:94` — `add_member`
  - `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:118` — `remove_member`
  - `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:106` (via `notify_cap_change/4`) — `grant_cap` / `revoke_cap`
  Each is an explicit `Ezagent.Notifications.notify(...)` call inside the action body — exactly the ad-hoc pattern model point 0.4 wants to eliminate.
- **`chat.ex:269` mixes two roles**: chat-the-message-delivery (0.1 producer of `Behavior.Chat`) *and* notification-of-affected-entity (0.2 owner of user's stream). The current code makes Chat the producer of *both*, but per the model, only the Chat dispatch should be Chat's responsibility; the User's `Chat.receive` slice change should be the notification trigger automatically.
- **Producer responsibility is split across tiers inconsistently**: `domain_workspace` (the actor's domain) emits the notification for the affected user; `domain_identity` (the actor's domain) emits it via `notify_cap_change/4`; but `domain_chat` emits it via the receive-side behavior. Three different patterns for what should be one auto-mechanism.
- **No CI gate forbids a new producer from skipping the helper.** Per audit Finding 1, the `check_invariants` PubSub allowlist allows direct `Phoenix.PubSub.broadcast(... topic("esr:user:..."))` from any module today. A plugin author can copy the legacy `chat.ex:261-265` pattern and bypass the cap check + telemetry + audit, with zero test failure.
- **`chat.ex:261-265` legacy raw broadcast still fires in parallel** to the new helper path — the "transition window" never closed. Two independent producers, same topic, different envelope shapes — exactly the divergence P3 forbids.
- **Snapshot diff and notification diff are computed independently.** `Ezagent.Kind.Snapshot.maybe_save/4` already implements `new_slice != old_slice` semantics inside `server.ex:128/134/148/156`. A second pass (the proposed notification hook) needs the same comparison and should not re-derive it.
- **The validate-rejected / cap-denied / cross-workspace-denied paths could fire notifications today**, because the Behavior author controls when `notify/3` is called — typically right after writing the slice, but nothing prevents calling it in an error branch. The model point 0.4 implicit guarantee ("notify only on real mutations") is by-convention today.

---

## 2. Target architecture

### 2.1 The mechanism — slice-diff hook in `Ezagent.Kind.Runtime`

The single auto-emission hook lands inside `Ezagent.Kind.Runtime.handle_dispatch/4`, between the existing `invoke_behavior/5` success branch (line 82-85) and the existing `[:ezagent, :invoke, :stop]` telemetry emission (line 88-99). Server-level snapshot save (`server.ex:128/134/148/156`) stays where it is — the hook fires from inside Runtime so dispatch and notification share the same `new_slice / old_slice / slice_key` triple already computed in the with-chain.

**Hook contract** (informal — the real signature lands in PR-N1):

```elixir
# Inside Ezagent.Kind.Runtime.handle_dispatch/4, after step 9
# (`new_state = Map.put(state, slice_key, new_slice)`) and before
# step 10 (telemetry).

if new_slice != old_slice do
  Ezagent.SliceChange.emit(%{
    self_uri:        self_uri,
    kind_module:     kind_module,
    behavior_module: behavior_module,
    action:          action,
    old_slice:       old_slice,   # for diff-aware subscribers (optional consumer-side)
    new_slice:       new_slice,
    caller:          ctx[:caller],
    workspace_uri:   workspace_uri_of(self_uri),
  })
end
```

**The error branch (`{:error, reason}`) emits nothing.** This is the structural guarantee that notifications fire only on real mutations — a property no current code path enforces.

**`Ezagent.SliceChange.emit/1`** is a thin core module that:

1. Broadcasts on the entity's notification topic (`Ezagent.Notifications.topic(self_uri)`) for User Kinds; broadcasts on a parallel scheme-keyed topic for non-User scopes (Workspace, Session — these will need topic-shape extension; see open question 5.1).
2. Emits `[:ezagent, :slice_change, :emitted]` telemetry so audit pipeline picks it up automatically. (Replaces the current `[:ezagent, :notification, :emit]` from `notifications.ex:99-107` — the new event is the canonical signal, the old one is dropped post-migration.)
3. Honors no cap check on emission. Emission is structural; subscription is cap-gated (see 2.3).

**Topic shape** (proposed; subject to open question 5.1):

| Affected entity scheme | Topic |
|---|---|
| `entity://user/...` | `esr:entity:<uri>:slice_changed` (parallel to existing `esr:user:<uri>:events`; eventually replaces it) |
| `entity://agent/...` | `esr:entity:<uri>:slice_changed` |
| `workspace://<name>` | `esr:workspace:<name>:slice_changed` |
| `session://<template>/<workspace>/<name>` | `esr:session:<uri>:slice_changed` |
| `template://...`, `resource://...`, `system://...` | `esr:<scheme>:<uri>:slice_changed` (these are cross-cutting; expected zero subscribers in v1 but reserved for future) |

A unified per-URI shape (`esr:entity:<uri>:slice_changed`) is preferred over the current per-scheme shape (`esr:user:<uri>:events`) because the auto-hook treats all Kinds uniformly — the scheme prefix in the URI is sufficient; a separate `esr:user:` vs `esr:agent:` distinction is redundant and forces the helper to branch on Kind. Subscribers that only care about User events still subscribe per-URI; the topic doesn't need to encode the Kind.

### 2.2 What `Notifications.notify/3` becomes

Three viable end-states; recommendation in §5.

**(a) Deleted entirely.** Every producer site is migrated to the auto-hook; the helper has no callers. `Ezagent.Notifications` becomes a subscriber-side helper module (just `topic/1` + `subscribe/2` + `unsubscribe/1`); the producer side (`notify/3`) is removed. The audit telemetry event `[:ezagent, :notification, :emit]` is replaced by `[:ezagent, :slice_change, :emitted]`. **Cleanest from a P3 standpoint** — exactly one path; no helper to misuse.

**(b) Repurposed for cross-entity payload-carrying notifications.** The auto-hook handles "slice changed" events with no semantic payload (just the diff). A residual class of notifications carries a *payload* the consumer needs (e.g. "you were @mentioned in message M") — for these, `notify/3` survives as the *opt-in* path the Behavior calls *in addition* to the auto-hook. This is the migration-friendly option but reintroduces the dual-path problem (0.4) the model wants to eliminate.

**(c) Becomes a private, internal helper.** `notify/3` is marked `@doc false`, its only legitimate caller is `Ezagent.SliceChange.emit/1`, and an invariant test forbids it being called from anywhere else. The public producer surface is exactly: "mutate the slice; the auto-hook fires." Cross-entity payload cases (option b's residual) are handled by the auto-hook attaching the action's return value (`result` from `Ezagent.Kind.Runtime.handle_dispatch/4` step 8) to the slice-change event, so subscribers see both the diff and any structured result the action returned. **Recommended** — see §5.

### 2.3 Subscriber model

All subscribers (Flash, Feishu plugin, mobile push, audit log, future inbox LV) subscribe to the *same* topic shape (§2.1) via the *same* helper:

```elixir
Ezagent.Notifications.subscribe(affected_entity_uri, ctx)
```

The helper internally derives the topic from the URI's scheme. The cap check (currently `:subscribe` against the User Kind) generalizes to "cap to subscribe to entity X's slice-change stream" — needs `Ezagent.Capability.cap_for_action/3` entry per Kind. For non-User Kinds, the default cap shape is debated in open question 5.2.

**No subscriber-side change is required for AdminLive (PR #300) beyond the topic-shape migration.** The handler `handle_info({:notification, _, payload}, socket)` at `admin_live.ex:257-259` already handles the existing envelope; the new envelope is a strict superset (more fields), so the existing flash-bridge code keeps working.

Subscriber-side ergonomics layer (deferred to a follow-up SPEC):

- **Diff-aware subscriber** — a wrapper that exposes `subscribe_to_field(uri, slice_key, field, callback)`. Builds on the raw stream; lets a LV listen for "Bob's `caps` changed" without re-implementing diff logic.
- **Telemetry-only subscriber** — for operators (audit, observability LV) who want every slice change across the system, subscribe to telemetry (`[:ezagent, :slice_change, :emitted]`) instead of per-URI PubSub topics.

### 2.4 Chat's right place

> *Chat = send to another entity. The MESSAGE_RECEIVED slice change on the receiver side IS the notification. So chat producer doesn't notify; the recipient's `:chat` slice mutation auto-emits.*

Concretely:

- `Behavior.Chat.invoke(:send, slice, args, ctx)` stays as-is: writes to MessageStore, dispatches `:receive` to each routed recipient. **No `Notifications.notify/3` call.** No legacy PubSub broadcast.
- `Behavior.Chat.invoke(:receive, slice, %{message: msg}, ctx)` when `ctx.kind_module == User`: appends `msg` to the user's chat slice (or whatever the User's chat-receive state mutation is). **No `Notifications.notify/3` call.** The auto-hook in `Ezagent.Kind.Runtime` detects `new_slice != old_slice` and emits the slice-change event for the user URI.
- `Behavior.Chat.invoke(:receive, ...)` when `ctx.kind_module == Agent`: still sends to the bound `BridgeRegistry` channel pid (this is *outbound to an external transport*, not an inbox semantic — Allen 0.1 confirms agents don't have inboxes). No auto-hook fires either, because the Agent's slice doesn't change (the message is forwarded, not stored).
- The legacy `chat.ex:261-265` raw `Phoenix.PubSub.broadcast(... {:message_received, msg})` is **deleted** as part of this migration. There is no transition-window dual-shape coexistence in the target state; the auto-hook envelope is the only producer.

**This is a strict simplification of `chat.ex`**: the entire `:receive` User-branch shrinks to "append `msg` to the receive slice; return `{:ok, new_slice}`". The 30-line block at `chat.ex:244-279` (legacy broadcast + new `Notifications.notify`) collapses to ~5 lines.

---

## 3. Migration plan (PR-sized chunks)

Five PRs. The order is chosen so each step is independently verifiable and the system stays green between PRs. Per `feedback_let_it_crash_no_workarounds`, the final PR is a one-shot deletion sweep — no parallel paths persist post-migration.

### PR-N1: Land the auto-hook (no behavioral change yet)

- Add `Ezagent.SliceChange.emit/1` (new module, ~30 LOC).
- Add `Ezagent.SliceChange.topic/1` (per-Kind topic-shape helper).
- Insert the hook into `Ezagent.Kind.Runtime.handle_dispatch/4` between step 9 and step 10. Gated by a temporary feature predicate `enabled?/0` that returns `false` until PR-N3 — so the hook compiles and is shape-checked but emits nothing.
- Telemetry event `[:ezagent, :slice_change, :emitted]` added to `Ezagent.Audit.@events` build_row clause (mirror existing `[:ezagent, :notification, :emit]` clause).
- New test file `apps/ezagent_core/test/ezagent/slice_change_test.exs`: verifies hook fires for synthetic Behavior on synthetic Kind when slice changes; verifies hook does NOT fire on `{:error, _}` invoke return; verifies hook does NOT fire when `new_slice == old_slice`.
- **No producer-site or consumer-site changes.** `Notifications.notify/3` still works; AdminLive still subscribes to the legacy topic.

### PR-N2: Subscriber-side topic migration (consumer code, no producer change)

- Add `Ezagent.Notifications.subscribe_slice_change/2` (new helper; subscribes to the new `esr:entity:<uri>:slice_changed` topic). Keep `Ezagent.Notifications.subscribe/2` (subscribes to the legacy `esr:user:<uri>:events` topic) — both are valid, both work, during transition.
- `AdminLive.mount/3` (`admin_live.ex:108`) subscribes to BOTH the legacy topic AND the new topic. `handle_info({:slice_changed, ...}, socket)` clause added alongside the existing `{:notification, ...}` clause.
- Add an opt-in `subscribe_to_field/4` ergonomics helper if needed (or defer).
- **No producer-side changes.** The new topic has zero producers until PR-N3.

### PR-N3: Flip the auto-hook on; migrate one producer

- Flip `Ezagent.SliceChange.enabled?/0` to `true`.
- Migrate `Behavior.Chat.invoke(:receive, ...)` User-branch to rely on the auto-hook: delete the `Notifications.notify(...)` call at `chat.ex:268-277`; delete the legacy raw broadcast at `chat.ex:261-265`. The User-branch reduces to "append `msg` to the receive slice; return `{:ok, new_slice}`".
- The auto-hook fires on the slice change, emits to the new topic, AdminLive picks it up via the PR-N2 subscription.
- The existing `[:ezagent, :notification, :emit]` telemetry continues to fire from the surviving `Notifications.notify/3` call sites (workspace, identity); audit pipeline sees both events.
- New integration test: send a message, verify (a) AdminLive receives `{:slice_changed, ...}` and (b) the legacy `{:notification, ...}` is NOT emitted for this code path anymore.
- **Producer pattern proven on one site before sweeping.**

### PR-N4: Migrate remaining producer sites

- `Workspace.add_member/2` (`workspace.ex:94`) — delete the `Notifications.notify(...)` call. The auto-hook fires on the workspace slice change for the workspace URI; the affected user subscribes to `esr:workspace:<name>:slice_changed` OR (if member-add is also recorded in the user's slice via a User Behavior) on the user's own topic. **Decision required (open question 5.2):** is "workspace member added" a workspace-slice-change event the affected user subscribes to, OR does the workspace mutation also dispatch a side-effect mutation to the user's slice? Recommendation: the latter (P10 "shared referent needs identity" — the user's membership IS a user-slice fact, which dispatches as a User-Behavior action and triggers the auto-hook on the user's URI).
- `Workspace.remove_member/2` (`workspace.ex:118`) — same treatment.
- `Identity.invoke(:grant_cap, ...)` (`identity.ex:106` via `notify_cap_change/4`) — delete the helper call. The auto-hook fires on the User's identity-slice change (caps field mutated). Subscribers see the slice diff and can render "your cap set changed."
- `Identity.invoke(:revoke_cap, ...)` — same.
- All 4 ad-hoc `Notifications.notify/3` call sites deleted. Only the helper definition survives, callable from nowhere except (in PR-N5) the `SliceChange.emit/1` internal path.

### PR-N5: One-shot deletion sweep (drift-prevention lockdown)

- `Ezagent.Notifications.notify/3` is reduced to a private/internal function (option 2.2.c). Mark `@doc false`; rename to `notify_internal/3` to surface accidental callers as compile errors.
- `Ezagent.Notifications.subscribe/2` and `topic/1` survive as the subscriber-side public API (option 2.2.c shape).
- Delete the legacy `[:ezagent, :notification, :emit]` telemetry event from `Ezagent.Audit.@events` and the matching build_row clause. The `[:ezagent, :slice_change, :emitted]` event is now the only audit signal.
- Delete `AdminLive.subscribe(... Notifications.topic(caller_uri))` (the legacy subscription from PR #300); the slice-change subscription added in PR-N2 is the only path.
- Delete the legacy `handle_info({:notification, _, _}, socket)` clause at `admin_live.ex:257-259`; the `handle_info({:slice_changed, ...}, socket)` clause is the only path.
- Add the three drift-prevention invariant tests (§4). These are the gate that closes PR-N5; the migration is not "done" until they exist and fail under simulated regression.

---

## 4. Drift prevention

Per P6 (completion claim requires invariant test), each invariant below is paired with a test that *fails* when the architectural rule is violated. Without the failing-when-violated test, the rule silently regresses on the next PR.

### Invariant 1 — No direct `Ezagent.Notifications.notify_internal/3` call outside the runtime hook

**Statement**: Only `Ezagent.SliceChange.emit/1` (and unit tests of `Ezagent.Notifications` itself) may call `Ezagent.Notifications.notify_internal/3`. Any other module that references the symbol is a regression to the ad-hoc pattern.

**Test** (sketch): a grep gate inside `Mix.Tasks.Ezagent.CheckInvariants`:

```elixir
# Invariant: notify_internal call sites are restricted.
allowed = [
  "apps/ezagent_core/lib/ezagent/slice_change.ex",
  "apps/ezagent_core/test/ezagent/notifications_test.exs"
]

offenders =
  for {file, _} <- grep("Ezagent.Notifications.notify_internal"),
      file not in allowed,
      do: file

assert offenders == [], "notify_internal called from non-allowlisted file(s): #{inspect(offenders)}"
```

**Mirror of**: existing gate #1 (PubSub.broadcast allowlist for audit / invocation / chat) at `check_invariants.ex:70-114`. Same enforcement style; same rationale.

### Invariant 2 — Every Behavior action that mutates a slice triggers exactly one slice-change event

**Statement**: For every `Behavior.invoke/4` call that returns `{:ok, new_slice, ...}` with `new_slice != old_slice`, the auto-hook MUST emit exactly one `[:ezagent, :slice_change, :emitted]` telemetry event. For every call that returns `{:error, _}` OR returns `{:ok, new_slice}` with `new_slice == old_slice`, zero events MUST be emitted.

**Test** (sketch): an integration test in `apps/ezagent_core/test/invariants/slice_change_exactly_once_test.exs`:

```elixir
test "every mutating dispatch emits exactly one slice_change event" do
  attach_telemetry([:ezagent, :slice_change, :emitted], self())

  # Dispatch a mutating action
  :ok = Invocation.dispatch(mutating_invocation())
  assert_receive {[:ezagent, :slice_change, :emitted], _, _}
  refute_receive {[:ezagent, :slice_change, :emitted], _, _}, 100
end

test "error-returning dispatch emits zero slice_change events" do
  attach_telemetry([:ezagent, :slice_change, :emitted], self())
  {:error, _} = Invocation.dispatch(error_invocation())
  refute_receive {[:ezagent, :slice_change, :emitted], _, _}, 100
end

test "no-op dispatch (slice unchanged) emits zero slice_change events" do
  attach_telemetry([:ezagent, :slice_change, :emitted], self())
  :ok = Invocation.dispatch(no_op_invocation())
  refute_receive {[:ezagent, :slice_change, :emitted], _, _}, 100
end
```

**Why this is the gate**: it is the test that *fails* if a future PR adds a `:warning`/degrade path inside the hook (P2 violation), or if a Behavior's `init_slice/1` is mistakenly counted as a mutation (causing spurious notifications on every Kind spawn), or if the auto-hook is bypassed for any reason. A green test means "the auto-emission semantic is intact"; a red test means "drift in progress, do not merge."

### Invariant 3 — No `Phoenix.PubSub.broadcast` to entity-stream topics from outside the runtime hook

**Statement**: The topics `esr:entity:<uri>:slice_changed`, `esr:workspace:<uri>:slice_changed`, `esr:session:<uri>:slice_changed` (and the broader `esr:<scheme>:<uri>:slice_changed` family) MAY only be broadcast to by `Ezagent.SliceChange.emit/1`. Direct `Phoenix.PubSub.broadcast(... "esr:entity:" <> ...)` from anywhere else is a regression to the bypass-the-helper pattern audit Finding 2 enumerated.

**Test** (sketch): extend the existing PubSub allowlist in `check_invariants.ex:70-114`:

```elixir
# Files allowed to broadcast on entity-stream topics:
slice_change_topic_allowlist = ["apps/ezagent_core/lib/ezagent/slice_change.ex"]

# Grep gate
offenders =
  for {file, line, _src} <- grep_broadcasts(~r/"esr:\w+:.*:slice_changed"/),
      file not in slice_change_topic_allowlist,
      do: {file, line}

assert offenders == [], "Slice-change topic broadcast from non-allowlisted file: #{inspect(offenders)}"
```

**Why this is structurally necessary**: per audit Finding 2, the cap-gated helper is a code-discipline gate, not a structural one — anything in the BEAM can `Phoenix.PubSub.broadcast` to any topic with no auth check. The grep-gate is the structural enforcement; it converts a runtime cap-bypass into a CI failure.

---

## 5. Open questions

Five questions requiring Allen decision before PR-N1 is ready to merge. Recommendations included.

### 5.1 Topic shape for non-User Kinds

Today `Ezagent.Notifications` only supports `entity://user/...` (`notifications.ex:177-183` raises on non-user URIs). The auto-hook applies to every Kind dispatch — including Workspace, Session, Agent, Template. Topic shape options:

- **(a)** Per-scheme topics: `esr:user:<uri>:events`, `esr:workspace:<uri>:events`, etc. — backwards-compatible with the existing legacy shape but multiplies the surface.
- **(b)** Unified per-URI topic: `esr:entity:<uri>:slice_changed` for all Kinds, where the URI's scheme is parsed out from the URI itself.
- **(c)** Per-Kind-module topic: `esr:<kind_module>:<uri>:slice_changed` — explicit but verbose.

**Recommendation**: **(b)**. The URI is the unique identifier; the scheme prefix in the URI is sufficient to disambiguate. Subscribers that care about User-only events subscribe per-User-URI; subscribers that care about a class of events (e.g. "all workspace slice changes" for an audit LV) subscribe via telemetry, not per-URI PubSub.

### 5.2 Member-add cross-entity semantics: workspace slice or user slice?

When admin Alice runs `Workspace.add_member(ws, bob_uri)`:

- Option (i): the workspace's slice changes (its `:members` list grows). The auto-hook emits on `esr:workspace:ws:slice_changed`. Bob's UI must subscribe to the workspace topic to see "I was added."
- Option (ii): the workspace's slice changes AND the workspace dispatches a side-effect User-action to update Bob's user slice (his `:memberships` field grows). Two auto-hook emissions: workspace topic + Bob's entity topic. Bob's UI subscribes to his own entity topic — the same topic he subscribes to for everything else about himself.

**Recommendation**: **(ii)**. Per P10 (shared referent needs identity) and Allen 0.2 (notification ownership = whoever is affected), Bob's membership IS a fact about Bob, not just about the workspace. The dispatch chain Workspace→User keeps the model honest: every entity sees its own slice-changes on its own topic, full stop. The workspace-topic event is for workspace-admin LVs that want to see "membership changed somehow."

### 5.3 What about cross-Kind action results that carry payload (e.g. `@mention` summary text)?

The auto-hook emits `{old_slice, new_slice, action, result}`. For Bob's chat-receive slice change, the `result` is `nil` (no return value from `Chat.invoke(:receive, ...)`). For an action like "you were @mentioned by Alice in message M", the *interesting* payload (mention text, source message URI, source user) is in the message itself — already on Bob's slice via the slice diff. So the slice-diff IS sufficient signal.

But for some imagined future action — say "Workspace.alert_member" that sends a one-shot popup with custom copy — the *only* signal is the action's `result`. Should the auto-hook expose `result` to subscribers? Or should "popup notifications with custom copy" be a separate primitive?

**Recommendation**: expose `result` in the slice-change event envelope; document that subscribers SHOULD prefer the slice diff over the `result` field for v1; defer "popup with custom copy" semantic to a separate SPEC when a real use-case lands. P8 ("less invented, more assembled") — don't add the abstraction speculatively.

### 5.4 Subscription cap shape for non-User Kinds

Today `Ezagent.Behavior.Notifications` registers `:subscribe` against `Ezagent.Entity.User` (`application.ex:186-187`). When the topic shape extends to Workspace, Session, etc. (per 5.1), each scope's cap shape must be defined:

- **Workspace**: cap to subscribe to a workspace's slice-change stream = workspace-member cap? Or workspace-admin cap? (Affects: who can build a "live workspace activity" LV.)
- **Session**: cap to subscribe to a session's slice-change stream = session-member cap (already exists for `Chat.send` access). Probably reuse.
- **Agent / Template / Resource**: deferred to v2; no current subscriber surface.

**Recommendation**: in PR-N5, define `:subscribe_slice_change` as a generic Behavior subject registered against User + Workspace + Session, with default cap shape = "any member of the scope". Plugins can register tighter caps if needed.

### 5.5 Init-slice vs mutation distinction

`Ezagent.Kind.Server` calls `behavior.init_slice/1` on Kind spawn (`server.ex` init path) and `behavior.invoke/4` on every dispatch. Init is technically a "slice change" (`nil → initial_slice`), but the model point 0.3 framing ("any Behavior `:invoke` that mutates") excludes init.

Should the auto-hook fire on init? Three options:

- **(a)** No — init is not invoke; the hook is in `handle_dispatch`, init runs elsewhere. Subscribers will not see "the Kind was just created" via this stream.
- **(b)** Yes — emit a `:slice_initialized` event on Kind spawn so subscribers (e.g. "list of recent users" LV) can react.
- **(c)** Defer — keep the hook dispatch-only in v1; add init-time emission in v2 if a real subscriber needs it.

**Recommendation**: **(c)**. Init is rare; most "new entity" subscribers want a *registration* event from a Behavior (e.g. `Identity.invoke(:register, ...)` that mutates the user's `:status` slice from `nil` to `:active`), which IS a dispatch. Pure spawn-time emission can wait.

---

## 6. What this DOES NOT change

To bound scope and avoid scaring reviewers, this SPEC is *only* about producer-side migration. Out of scope:

- **PR #300's `AdminLive` consumer wiring stays.** The subscription point shifts from `Notifications.topic(caller_uri)` to `SliceChange.topic(caller_uri)` in PR-N5, but the principle (LV subscribes; bridges to flash via `handle_info`) is preserved. The flash-bridge `handle_info({:notification, ...}, socket)` clause is renamed to `handle_info({:slice_changed, ...}, socket)` and otherwise unchanged.
- **PR #301's notification telemetry stays.** The event name changes (`[:ezagent, :notification, :emit]` → `[:ezagent, :slice_change, :emitted]`) in PR-N5 and the `Audit.@events` + `build_row/3` clause is renamed. Audit's role in the pipeline doesn't change.
- **`Ezagent.Behavior.Notifications` cap subject stays** (modulo 5.4 generalization to non-User Kinds). It is still the cap-only Behavior used for `:subscribe` authorization.
- **All non-notification PubSub broadcasts stay**: `Ezagent.Audit.stream_topic` (audit), `Ezagent.CCEvents.topic` (CC events), session-events topics (chat fan-out), bridge topic (cc plugin), presence diff (chat presence). These have nothing to do with the model points; their producers (`audit.ex`, `cc_events.ex`, `bridge_registry.ex`, `presence_fanout.ex`, `read_marker.ex`) keep their current `Phoenix.PubSub.broadcast` call sites.
- **MessageStore writes stay synchronous in `Chat.invoke(:send, ...)`.** The chat message is durable storage, not a notification — the auto-hook is orthogonal to message persistence.
- **Snapshot writes stay where they are.** `Ezagent.Kind.Snapshot.maybe_save/4` runs at the Server level (`server.ex:128/134/148/156`), AFTER `Runtime.handle_dispatch/4` returns. The new auto-hook runs INSIDE `Runtime.handle_dispatch/4` BEFORE returning — both fire on the same dispatch, but they have independent diff comparisons and independent failure semantics. (A snapshot write failure does NOT suppress the slice-change event; a slice-change emission failure does NOT suppress the snapshot.)
- **CapBAC / workspace-isolation steps (5.5 / 5.6 in `handle_dispatch`) stay.** The auto-hook fires only on successful invoke; cap-denied and cross-workspace-denied paths take the `{:error, _}` branch and emit no slice-change event. This is the structural guarantee in 0.4 — notifications cannot leak privilege.

---

## Pointer index

Code touched by the migration:

- `apps/ezagent_core/lib/ezagent/notifications.ex` — producer helper (private-ized in PR-N5)
- `apps/ezagent_core/lib/ezagent/behavior/notifications.ex` — cap subject (generalized in PR-N5)
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` — hook landing point (PR-N1)
- `apps/ezagent_core/lib/ezagent/slice_change.ex` — NEW module (PR-N1)
- `apps/ezagent_core/lib/ezagent/audit.ex` — telemetry event rename (PR-N5)
- `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` — three new gates (PR-N5)
- `apps/ezagent_core/lib/ezagent_core/application.ex:186-187` — Notifications cap registration (extended in PR-N5)
- `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:244-279` — User-branch simplified (PR-N3)
- `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:94, 118` — explicit notify calls deleted (PR-N4)
- `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:101-114` — `notify_cap_change/4` helper deleted (PR-N4)
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:108, 257-259` — topic + handler rename (PR-N2 + PR-N5)

Prior art consulted:

- `docs/notes/2026-05-24-notification-log-audit.md` — Notification + Log audit; Findings 1-3 motivate this SPEC
- `docs/notes/2026-05-24-notifier-flash-cli-parity-audit.md` — Notifier/flash + CLI parity audit; the consumer-side wiring and the 4-producer enumeration come from here
- `docs/superpowers/specs/2026-05-23-presence.md` — sibling cap-only Behavior pattern
- `docs/superpowers/specs/2026-05-23-read-receipts.md` — sibling slice-mutation event pattern
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` `maybe_save/4` — reference implementation of "diff-aware write" semantics the auto-hook should mirror

Principles enforced:

- **P3** — single source of truth: one auto-hook, one topic shape, one producer path
- **P6** — completion claim requires invariant test: three invariant tests in §4 are the gate
- **P14** — dispatch is the only path: auto-hook lives INSIDE the dispatch funnel; cannot be bypassed by callers
- **P19** — dispatch hygiene rule 3 (telemetry on every dispatch): the slice-change event piggybacks on the existing telemetry spine
- **P22** — reliability primitives in core, plugin authors cannot bypass: `Ezagent.SliceChange` is in core; plugins do not call it directly
