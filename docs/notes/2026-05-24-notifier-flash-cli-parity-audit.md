# Notifier ↔ Flash + CLI Notification Parity — 2026-05-24

> Read-only audit. No production code touched.
> Follow-up to `docs/notes/2026-05-24-notification-log-audit.md`.
>
> Allen's questions:
> 1. Notifier ↔ UI flash 关联 — when `Notifications.notify` fires, does a flash bubble up in any LV the user is viewing?
> 2. CLI/GUI same-source-derivation for notifications — when an LV action emits a notification, does the equivalent CLI action also emit it?

---

## Summary verdict

| Question | Answer | Severity |
|---|---|---|
| Q1: Notifier ↔ Flash correlated? | **No, not at all.** The two systems are completely disjoint surfaces with no bridge. They are not architecturally hostile — they're orthogonal by design — but no LV today converts an inbox `{:notification, ...}` into a user-visible flash, and Allen's prior intuition ("notification = Feishu-bound, flash = local UI ephemera") is **basically correct** for the way the code is *wired today*. The current `Ezagent.Notifications` is in fact intended for in-app inbox / push, but **the LV that should subscribe never subscribes**, so the broadcast is structurally orphaned and the would-be flash is never raised. | **HIGH** (architectural intent unfulfilled — feature ships dead) |
| Q2: CLI notification parity? | **Yes, automatically — but moot, because only ONE producer site exists.** Both LV and CLI flow through `Ezagent.Invocation.dispatch/1` (`Decision #130`, `cli_lv_same_server_invariant_test.exs`), so any Behavior that emits a notification fires for **both** surfaces. The producer side has parity-by-construction. The non-parity case is: actions that *should* emit a notification but *don't* — those don't emit it from either surface, so parity is preserved trivially. | **MED** (parity correct; coverage near-zero) |

---

## Q1: Notifier ↔ UI Flash correlation

### The two systems

- **`Ezagent.Notifications`** — per-user inbox primitive (`apps/ezagent_core/lib/ezagent/notifications.ex`). Producer calls `Notifications.notify(user_uri, %{type, body, source}, ctx)`; the helper broadcasts `{:notification, user_uri, payload}` on the user-scoped PubSub topic `esr:user:<uri>:events`. Subscriber pattern: any process can `Notifications.subscribe(user_uri, ctx)` and receive the envelope as a regular Erlang message.

- **Phoenix flash** — request-/socket-local ephemeral assigns rendered by `<.flash_group flash={@flash} />`. Producers: `put_flash(socket_or_conn, :info|:error, msg)` in controllers and LiveViews. Sinks:
  - `apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex:389-411` — `flash_group/1` shared component (PR-B, 2026-05-23) used by every admin/plugin LV via `use EzagentDomainUi.Components`.
  - `apps/ezagent_web/lib/ezagent_web/components/layouts.ex:71,80,85-116` — root web layout flash.
  - Per-LV `:if={@flash_error}` / `@flash_info` ad-hoc renderers — `entity_caps_live.ex`, `agent_detail_live.ex`, `workspace_detail_live.ex`, `user_api_keys_live.ex`, `snapshots_live.ex`, `profile_live.ex`, `users_live.ex`, `routing_live.ex`, `agent_new_live.ex`, `workspaces_live.ex`, etc. (legacy custom assigns that pre-date the shared `flash_group`.)

### Cross-wiring check — definitive result

Grep for "any LV subscribes to a user's notification topic":

```
grep -rn "Notifications.subscribe\|esr:user:.*:events\|user_events_topic" \
  apps/*/lib --include="*.ex" | grep -v notifications.ex | grep -v chat.ex
# → zero hits
```

**Zero LV (and zero web controller) subscribes to `esr:user:<uri>:events`.** Confirmed by checking all 28 LV `Phoenix.PubSub.subscribe` sites — every one targets either `Ezagent.Audit.stream_topic()`, the bridge topic, `Ezagent.CCEvents.topic()`, or a `session_events_topic(session_uri)`. None subscribes to a user-events topic.

What handles the `:notification` envelope today:

| File:line | Handler body | Notes |
|---|---|---|
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:245-247` | `def handle_info({:notification, _user_uri, _payload}, socket), do: {:noreply, socket}` | **No-op stub.** Comment (line 240-244): "the legacy `:chat_message` handler above already updates the stream; we just acknowledge the notification here so the LV doesn't crash." But the comment is misleading — AdminLive never subscribes to the user-events topic, so this clause is currently unreachable; it exists as defensive coverage for some hypothetical future subscription. |
| `apps/ezagent_core/test/ezagent/notifications_test.exs` | `assert_receive {:notification, _, _}` | Test process subscribes to verify the broadcast. |

**Therefore**: in production, `Notifications.notify/3` fires (the helper executes successfully, returns `:ok`), the message goes onto PubSub, **and the tree falls in a forest with no listeners**. No flash. No badge. No update. Allen's UX intuition ("nothing happens in the LV") matches reality.

### What MIGHT have happened (intent reconstruction)

From `apps/ezagent_core/lib/ezagent/notifications.ex:1-18` moduledoc and the PR-C commit context in the prior audit (§1): the helper was added (2026-05-23, "PR #276 / PR #281" per the admin_live comment) intending that "LV subscribes for admin inbox / mention notifications" — explicitly per `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:26-27` doc:

> `Ezagent.Entity.User` — broadcast to `esr:user:<self_uri>:events`. LV subscribes for admin inbox / mention notifications.

But the subscribe side was never landed. The system is half-built:

- ✅ Producer helper exists (`Notifications.notify/3`)
- ✅ Cap subject exists (`Ezagent.Behavior.Notifications`)
- ✅ Registration exists (`application.ex:186-187`)
- ✅ One producer migrated (`chat.ex:269`)
- ❌ **Zero consumers** beyond the unit test
- ❌ No flash bridge
- ❌ No badge / inbox-counter LV component

### What a notifier→flash bridge would look like

To make the existing producer reach the user's open LV tabs:

1. In any LV that should show inbox pings — typically `AdminLive` and the future `InboxLive` — subscribe on `mount/3 if connected?(socket)`:
   ```elixir
   :ok = Ezagent.Notifications.subscribe(
     socket.assigns.current_entity_uri,
     %{caps: socket.assigns.caller_caps}
   )
   ```
2. Add a `handle_info({:notification, user_uri, %{type: t, body: b, source: src}}, socket)` clause that either:
   - converts to flash: `{:noreply, put_flash(socket, :info, format_notification(t, b))}` (renders via shared `<.flash_group>`), or
   - appends to a streaming `inbox` assign for a dedicated inbox panel (more durable than flash).
3. Update the AdminLive comment + drop the unreachable no-op once a real handler exists.

This is roughly ~15 LOC per LV that opts in.

### Verdict for Q1

**Today the two systems are not correlated — at all.** The notification primitive's producer is wired; its consumer-of-interest (LV inbox / flash bridge) is missing. The architectural intent ("user opens an LV → gets a flash when they're @mentioned in another tab") is **not satisfied by the code as it ships today**. This is a structural gap, not an explicit design decision to keep them separate.

That said, **they SHOULDN'T be the same primitive**:
- Flash is request/socket-scoped, ephemeral, dies on next render — appropriate for "your action just succeeded / failed."
- Notifications is per-user inbox — appropriate for "something happened TO you while you were elsewhere."

They should be **bridged where it makes sense (LV inbox → put_flash for ephemeral pings + badge for inbox)**, not merged.

---

## Q2: CLI-emit-notification parity

### Structural answer

Both LV and CLI dispatch through the same `Ezagent.Invocation.dispatch/1` chokepoint:

- LV — every `handle_event` mutation calls `Ezagent.Invocation.dispatch(%Ezagent.Invocation{...})`. Confirmed 17 dispatch sites across `admin_live.ex`, `entity_caps_live.ex`, `agent_detail_live.ex`, `user_api_keys_live.ex`, `routing_live.ex`, `agent_new_live.ex`, `agent_extensions_live.ex`. (Some LV-only legacy paths bypass dispatch — see Finding 2 below — but those don't emit notifications either, so they don't break parity.)
- CLI — `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:199-214` calls `Invocation.dispatch(inv)` after Identity resolution. The pivot to distributed-Erlang RPC (`Mix.Tasks.Esr`, Decision #130) means `EzagentCli.Exec.exec/1` runs **inside the runtime BEAM** — same process tree, same KindRegistry, same telemetry, same notification helper. Locked by `apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs`.

**Therefore**: any Behavior whose `invoke/4` calls `Ezagent.Notifications.notify/3` fires the notification regardless of whether the invocation came from LV `handle_event` or `mix ezagent <kind> <action>`. **Parity is automatic at the producer site.** This is exactly the chokepoint hygiene that `Notifications.notify` was added to enforce (per P3 single-source-of-truth — see prior audit Finding 1).

### Empirical answer — only one producer exists today

```
grep -rn "Ezagent\.Notifications\.notify\b" apps --include="*.ex" | grep -v _test.exs
# → apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:269  (the only call site)
```

The single producer is `Behavior.Chat.invoke(:receive, ...)` when `ctx.kind_module == Ezagent.Entity.User` — i.e. a chat message routed TO a user fan-outs through `:receive` which calls `Notifications.notify(user_uri, %{type: :message_received, body: %{msg: msg}, source: __MODULE__}, %{caps: :system})`.

Crucially: the **caller** (sender) doesn't trigger the notification directly — `Behavior.Chat.invoke(:send, ...)` at `chat.ex:215-221` calls `Ezagent.Routing.Resolver.resolve/4` and then dispatches `:receive` to each recipient. The recipient's `:receive` handler is what calls `Notifications.notify`. This means:

- `mix ezagent session send --session ... --message ...` (auto-derived CLI from `Chat.@interface[:send]`) **DOES** fan out into `:receive` for every routed recipient → DOES call `Notifications.notify` for any User recipient. ✅ Parity.
- `mix ezagent session join` doesn't notify the added member of being invited — neither does the LV `invite_member` path. ❌ Symmetric absence.
- `mix ezagent workspace add_member` doesn't notify the added user — neither does LV `workspace_detail_live.ex:136` `add_member`. ❌ Symmetric absence.
- `mix ezagent user grant_cap` (auto-derived from `Identity.@interface[:grant_cap]`) doesn't notify the grantee — neither does any LV cap-grant. ❌ Symmetric absence.

### CLI-reachable actions that arguably SHOULD emit notifications but don't (from any surface)

Audit of all `def invoke(action, slice, args, ctx)` clauses in `apps/*/lib/ezagent/behavior/*.ex`:

| Behavior.Action | Should notify? | Today notifies? (LV / CLI) | Gap |
|---|---|---|---|
| `Chat.send` → fan-out → `Chat.receive` → User | yes | ✅ yes (both) | none — parity correct |
| `Chat.send` → fan-out → `Chat.receive` → Agent | n/a (agents don't have inbox; see prior audit §1 `notifications.ex:162-168`) | no | by design |
| `Chat.join` | recipient (added member) probably wants a "you were added to session X" ping | ❌ neither | ⚠️ MED — symmetric absence |
| `Chat.leave` | the leaver doesn't care; remaining members maybe care | ❌ neither | ⚠️ LOW |
| `Workspace.add_member` | added user wants "you joined workspace X" | ❌ neither | ⚠️ MED |
| `Workspace.remove_member` | removed user wants "you were removed from X" | ❌ neither | ⚠️ MED — silent removal is a real UX failure |
| `Workspace.set_routing_rules` | session owners / admins | ❌ neither | LOW |
| `Identity.grant_cap` | grantee wants "you got a new cap" | ❌ neither | ⚠️ MED — security-relevant; user should know their privileges changed |
| `Identity.revoke_cap` | grantee wants "you lost cap X" | ❌ neither | ⚠️ MED — same |
| `ApiKeys.put_api_key` / `delete_api_key` | self-targeted; user already knows | ❌ neither (correct) | none |
| `Routing.add_rule` / `delete_rule` / `disable_rule` / `enable_rule` | workspace admins | ❌ neither | LOW |
| `Lifecycle.terminate` | the terminated agent's owner | ❌ neither | LOW |
| `Pty.write` / `Pty.resize` | per-agent transport; not user-visible | ❌ neither (correct) | none |
| `Presence.*` | already fan-out via Presence diff PubSub; doesn't need inbox | n/a | none |
| `Sandbox.*` / `Template.*` | infra | n/a | none |

**Pattern**: every "X just happened to user U" action that mutates U's state across a session/workspace boundary lacks a notification. The mention-routing path (the one Allen explicitly tested with `mention_gated_routing_test.exs`) is the only one wired.

This is a **policy gap**, not a parity gap. Once you add `Notifications.notify` to (say) `Workspace.add_member`, both `mix ezagent workspace add_member ...` AND `workspace_detail_live.ex` `add_member` event will fire it — for free, because both go through `Invocation.dispatch`.

### One edge case worth flagging — LV-only paths that bypass dispatch entirely

Per prior audit (`docs/notes/2026-05-24-cli-gui-parity-audit.md` §1):

> Several user-facing GUI actions live behind LV-only "facade" code paths that call private domain APIs directly: `Ezagent.Users.create`, `Ezagent.Workspace.add_member`, `Ezagent.Entity.Profile.upsert`, `Ezagent.AppSettings.put`, `Ezagent.Workspace.create`.

These bypass `Invocation.dispatch` from the LV side, which means:

1. They don't appear in `mix ezagent <kind> <action>` (the dispatch tree-builder doesn't see them) → CLI cannot perform these mutations.
2. If a future PR adds `Notifications.notify` to (say) `Behavior.Workspace.invoke(:add_member, ...)`, the LV `workspace_detail_live.ex:136` add_member event **would not trigger it** because LV calls `Ezagent.Workspace.add_member/2` directly — not the Behavior action.

So the parity claim has an asterisk: **for Behaviors that are actually invoked via dispatch from BOTH surfaces, parity is automatic. For Behaviors that LV invokes via private API and CLI cannot invoke at all, no parity exists because there's only one surface (LV) and even that one bypasses the dispatch chokepoint where the notification would fire.** This is the same anti-pattern P14 forbids; it's a known gap (prior audit Finding §3.1).

### Verdict for Q2

**Yes — parity is structural and correct on the dispatch path.** Both LV and CLI flow through `Invocation.dispatch/1`; any Behavior that emits a notification will emit it for either surface identically. The current scope of notifications (one producer, only chat-receive-to-user) means the parity story is *trivially* satisfied but not very interesting yet.

**The bigger gap is policy**: ~6 cap-relevant or membership-relevant actions arguably should emit notifications and don't, from either surface. Adding `Notifications.notify` calls to those Behavior actions would propagate to CLI for free.

**The asterisk**: LV-only private-API paths (`Workspace.add_member/2` direct call) exist outside the dispatch chokepoint. Notifications added to the corresponding Behavior won't fire for those LV events until the LV is migrated to dispatch. This is a P14 issue (prior audit) — fixing P14 incidentally fixes the asterisk.

---

## Findings

### Finding 1 — Notification consumer side never landed; `Notifications.notify` is structurally orphaned (HIGH)

- **What:** Producer exists, helper compiles, broadcast fires, but zero LV/web/controller subscribes to `esr:user:<uri>:events`. The only subscriber today is the unit test process. The unique `handle_info({:notification, ...})` clause in `admin_live.ex:245` is **unreachable** — comment says "the legacy `:chat_message` handler above already updates the stream" but `:chat_message` flows on session topics, not user topics, so this no-op handler covers a subscription that doesn't exist.
- **Where:** `apps/ezagent_core/lib/ezagent/notifications.ex:94-99` (producer) vs absence in all LV mounts.
- **Why it matters:** Doc says "LV subscribes for admin inbox / mention notifications" (`chat.ex:26-27`). It doesn't. The mention-routing test (`mention_gated_routing_test.exs:9`) verifies the broadcast happens, but no integration test verifies a real LV would surface it to a real user. P6 (completion claim requires invariant test) is violated — the system passes its tests but doesn't deliver the documented UX.
- **Recommendation:** Either (a) finish the consumer side — add `Notifications.subscribe(socket.assigns.current_entity_uri, ctx)` in `AdminLive.mount/3` + a real `handle_info` that converts to `put_flash` / appends to an inbox stream + delete the misleading no-op; OR (b) explicitly mark `Ezagent.Notifications` as "API-stable; UI surface deferred to V2" in the moduledoc, with a clear pointer to where the consumer will land. Option (a) is ~30 LOC and would actually satisfy the documented intent.

### Finding 2 — Notifier ↔ Flash bridge is missing; "you got a notification in another tab" UX impossible today (MED)

- **What:** There is no code path from `Notifications.notify` to `put_flash`. A user's open LV tab cannot show a flash for a notification raised on their behalf.
- **Where:** N/A — the bridge doesn't exist.
- **Why it matters:** The two systems are designed for different lifetimes (flash = render-cycle; notification = user-inbox), but the natural UX bridge ("flash a brief banner when an inbox event arrives while the user is on a different LV") is a 5-line `handle_info` clause that nobody wrote. Until it's added, the only signal a user gets for an `@mention` while viewing the `/admin/workspaces` LV (say) is the absence of a signal.
- **Recommendation:** Add a `flash_from_notification/2` helper in `EzagentDomainUi.Components` that takes a notification map and returns `{key, msg}` suitable for `put_flash/3`. Wire it from any LV that calls `Notifications.subscribe` (Finding 1 first). ~10 LOC helper + 3 LOC per LV that opts in.

### Finding 3 — ~6 cap/membership actions lack notifications from either surface (MED)

- **What:** `Workspace.add_member`, `Workspace.remove_member`, `Chat.join` (added member), `Identity.grant_cap`, `Identity.revoke_cap` all mutate user-visible state without notifying the affected user. CLI and LV are symmetrically silent.
- **Where:** Each Behavior's `invoke/4` returns `{:ok, slice}` directly with no `Notifications.notify` call. See full table in §Q2 above.
- **Why it matters:** Security-relevant changes (grant_cap, revoke_cap, workspace membership) are silent state mutations from the affected user's perspective. P27 (silent drops in logs are never OK; silent drops to clients only OK if security-motivated) is on the *response* axis — adjacent principle for "user is affected and not told" is implied by P4 (production-usability) and P18 (no silent drops at user-facing surfaces). The cap-grant case is the sharpest: the user's authz just changed and they get no signal.
- **Recommendation:** Once Finding 1 + 2 are landed (so there's a consumer), add `Notifications.notify(target_user_uri, %{type: :cap_granted, body: %{cap: cap}, source: __MODULE__})` to each of the 5-6 actions. Parity-by-construction means CLI fires the same notification for free.

### Finding 4 — LV-only private-API paths bypass the notification chokepoint (MED, but covered by existing P14 finding)

- **What:** `workspace_detail_live.ex:136` `add_member` calls `Ezagent.Workspace.add_member/2` (not the Behavior action), so any future `Notifications.notify` added to `Behavior.Workspace.invoke(:add_member, ...)` won't fire for the LV event. Same anti-pattern: `users_live.ex` direct `Ezagent.Users.create`, `agent_new_live.ex` direct `Ezagent.Workspace.add_template`, etc.
- **Where:** Already enumerated in `docs/notes/2026-05-24-cli-gui-parity-audit.md` §1 (P14 violations listed as Finding 3 there).
- **Why it matters:** Same root cause as the prior audit — fixing the P14 violation by routing these LV events through `Invocation.dispatch` would incidentally fix the notification parity for them as well. Two birds, one stone.
- **Recommendation:** No new recommendation; tracked under prior audit. Just noting the cross-cut.

### Finding 5 — `:notification` no-op handler is misleading (LOW)

- **What:** `admin_live.ex:245-247` `def handle_info({:notification, _user_uri, _payload}, socket), do: {:noreply, socket}` with a comment claiming it coexists with the legacy `:chat_message` handler. The comment is technically true (both clauses are present) but functionally wrong — AdminLive never subscribes to the user-events topic, so this clause is unreachable in production. Removing the comment + the no-op would not break any test.
- **Where:** `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:240-247`
- **Why it matters:** Anti-pattern P2 ("let it crash; no defaults/workarounds"). The no-op clause exists as defensive coverage for a subscription that doesn't exist — exactly the "absorb the change in a default" shape P2 forbids. If a future PR DOES add `Notifications.subscribe` to AdminLive, the author will see the no-op and assume the handler is wired; they may not notice that the body is empty.
- **Recommendation:** Either delete the clause + comment (let-it-crash if a future subscribe lands without a real handler) OR wire a real handler now (Finding 1).

### Finding 6 — Flash_group has TWO implementations + several LVs use ad-hoc @flash_error / @flash_info (LOW, drift risk)

- **What:** Three flash render surfaces coexist:
  - `EzagentDomainUi.Components.flash_group/1` (PR-B, the canonical shared component, `:info` + `:error` from `Phoenix.Flash`)
  - `EzagentWeb.Layouts.flash_group/1` (the web-side stack, includes client-error + server-error banners)
  - Per-LV `:if={@flash_error}` / `@flash_info` (legacy custom assigns at ~12 LV files)
- **Where:** `apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex:389` vs `apps/ezagent_web/lib/ezagent_web/components/layouts.ex:85` vs `entity_caps_live.ex:256`, `agent_detail_live.ex:324`, `workspace_detail_live.ex:486`, `user_api_keys_live.ex:212`, `snapshots_live.ex:202`, `profile_live.ex:155`, `users_live.ex:608`, `routing_live.ex:719`, `agent_new_live.ex:498`, `workspaces_live.ex:137`, `agent_extensions_live.ex:324`.
- **Why it matters:** P3 (single source of truth) — `flash_group` was added explicitly to consolidate per-LV drift ("replaces the per-LV inline flash render patterns that had drifted", per the moduledoc), but the legacy `@flash_error` / `@flash_info` assigns at ~12 LV files were never migrated. A flash bridge for notifications (Finding 2) would have to pick one — and the LVs with custom assigns would not receive it without changes.
- **Recommendation:** Either (a) finish the PR-B migration — move all `@flash_error` / `@flash_info` LVs to `put_flash(:error, ...)` + `<.flash_group flash={@flash} />`; OR (b) extend the shared `flash_group` to read the custom assigns as a fallback (less clean). (a) is the P2-shaped fix.

---

## Recommended next steps

In priority order:

1. **Make a decision on the notifier-consumer story (HIGH).** Either land Finding 1 + 2 (add `Notifications.subscribe` + flash bridge in `AdminLive`) or explicitly mark `Notifications` as producer-only-pending-consumer in moduledoc + a Findings file. Current state is "feature ships dead with a misleading no-op."

2. **Add an invariant test for the notification surface (P6, MED).** `mention_gated_routing_test.exs` verifies the broadcast; add a sibling integration test that verifies a real LV-mounted under a real user receives the envelope and reflects it in the rendered HTML (e.g. an inbox badge increment or a flash). Until this test exists, the notification feature can silently regress at any time without any test failing.

3. **Finish the flash_group consolidation (LOW, prerequisite for #1).** Migrate the ~12 LVs with custom `@flash_error` / `@flash_info` assigns to `put_flash` + `<.flash_group>` so the bridge in #1 reaches all admin LVs uniformly.

4. **Resolve LV-bypasses-dispatch (cross-cut with prior CLI/GUI parity audit).** Migrate `workspace_detail_live.ex` `add_member`, `users_live.ex` `create_user`, `agent_new_live.ex` `add_template`, etc. to dispatch — this fixes Findings 3 (parity) and 4 (notification fan-out) simultaneously.

5. **Once consumer side lands, sweep the 5-6 actions in Finding 3** with `Notifications.notify` calls. Parity is free.

---

## Pointer index

- `apps/ezagent_core/lib/ezagent/notifications.ex` — producer helper
- `apps/ezagent_core/lib/ezagent/behavior/notifications.ex` — cap subject
- `apps/ezagent_core/lib/ezagent_core/application.ex:166-190` — registration
- `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:269` — only producer call site
- `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:215-221` — fan-out (`:send` → `:receive` per recipient)
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:245-247` — unreachable no-op handler
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:95-103` — actual subscribe list (no user-events topic)
- `apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex:389-411` — canonical `flash_group`
- `apps/ezagent_web/lib/ezagent_web/components/layouts.ex:85-116` — web-side `flash_group`
- `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:199-222` — CLI dispatch (chokepoint shared with LV)
- `apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs` — CLI ↔ LV runtime parity invariant
- `apps/ezagent_core/test/ezagent/notifications_test.exs` — only place anyone subscribes today
- `docs/notes/2026-05-24-notification-log-audit.md` — prior audit (notification + log subsystems)
- `docs/notes/2026-05-24-cli-gui-parity-audit.md` — prior audit (CLI / LV / web parity)
