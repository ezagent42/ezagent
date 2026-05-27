# Phase 2.6 — Session `:mode` (auto/takeover) + AI fan-out gating

AutoService → ezagent migration. Implements session-level operator-control
mode on ezagent's Session Kind, gates AI-sender messages from the
customer-visible fan-out when in `:takeover`, and pushes a verbatim
`"(客服已接管对话)"` notice on the `:auto -> :takeover` transition.

## Shape decision — (a) Behavior

Picked option (a): new `Ezagent.Behavior.Mode` module with its own
`:mode` slice and `:set` / `:get` actions, registered on
`Ezagent.Entity.Session`.

Reasoning:
- **Generic primitive (constraint §2)**. Mode is the kind of knob any
  chat-business will want (customer-service today, sales-pilot /
  education-tutor / multi-channel-handoff later). A dedicated Behavior
  with its own slice keeps the wiring re-usable across Kinds — a future
  workspace-level or channel-level Mode would re-register the same
  Behavior module against a different Kind.
- **Matches the `OrchestratorAdmin` precedent** in the same domain
  (Behavior owns the cap shape + its own slice; Session simply lists it
  in `behaviors/0`).
- **Doesn't bloat the `:chat` slice** — that slice is already ~250 LOC
  of init_slice / docs and serves a distinct (membership + send
  bookkeeping) concern.

The cost is ~140 LOC for `mode.ex` vs ~10 LOC for option (b). Worth it
for the generic re-use posture.

## Gating point in `Chat.invoke(:send, ...)`

Chat now declares `reads_sibling_slices == [:mode]` so the runtime
injects `ctx[:sibling_slices].mode` into `invoke/4`. Inside `:send`:

1. `session_mode = ctx.sibling_slices.mode.mode |> fallback(:auto)`
2. `suppress? = session_mode == :takeover and agent_sender?(msg.sender)`
3. `agent_sender?/1` matches `%URI{scheme: "entity", host: "agent"}`
   (mirrors the existing `user_uri?/1` predicate one segment up).
4. When `suppress?` is true:
   - The `Phoenix.PubSub.broadcast({:chat_message, …})` on the
     session-events topic is **skipped** — that topic is what the
     customer-facing channel / general-bot SSE subscribers listen on.
   - The per-recipient `dispatch_receive` loop **skips User
     recipients** (`user_uri?/1`). Agent recipients (chained AI workers
     in the same session) still receive — agent-to-agent routing is
     not subject to the operator-takeover gate.
   - Cross-session fan-out (`recipient.scheme == "session"`) is
     unaffected; the target session has its own `:mode` slice and its
     own gate.
5. Persistence (`MessageStore.write/2`), the slice mutation
   (`last_message_id` / `last_message` / `send_cursor` bump), and the
   resulting SliceChange + external-mirror Publisher path are
   **untouched**. Operators see takeover-suppressed messages in their
   admin LV (which rides SliceChange, not the chat-message topic) and
   in `/sessions` history (which reads MessageStore).

Code: `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex`, the
`invoke(:send, ...)` clause around line 322 (new `session_mode` /
`suppress_customer_visible?` derivation) and the recipient `for` loop
right after.

## Notice mechanism

`Mode.invoke(:set, slice, %{mode: :takeover}, ctx)` detects the
`:auto -> :takeover` edge after the slice mutation and calls
`emit_takeover_notice(ctx)`:

- Constructs a synthetic `%Ezagent.Message{}` with
  - `sender = Ezagent.SystemPrincipal.uri("chat-router")`
    (closed-Catalog system principal — `system://chat-router` already
    carries the wildcard Chat cap, fitting the fan-out semantic and
    not requiring a new Catalog entry).
  - `body.text = "(客服已接管对话)"` exactly (verbatim, no i18n).
  - `body.is_takeover_notice = true` so customer-side renderers can
    style the notice without parsing text.
- Cast-dispatches `chat.send` against the session's own URI with
  `system://chat-router` caps. `:cast` is required because we're
  currently executing inside the Session GenServer call processing
  `mode.set` — a `:call` to self would deadlock (same precedent as
  `Chat.grant_first_join_owner_cap/2`).
- Chat persists the notice in the normal `MessageStore` path and
  broadcasts on `session_events_topic` — customer + operator both see
  it land naturally. The system-principal sender is NOT an
  `entity://agent/...` URI, so the takeover gate does **not**
  suppress the notice itself (correctness-critical).

Reverse edge (`:takeover -> :auto`) is silent — no notice. AutoService
matches.

Code: `apps/ezagent_domain_chat/lib/ezagent/behavior/mode.ex`.

## Test results — five acceptance scenarios

All five scenarios pass under `apps/ezagent_domain_chat/test/ezagent/behavior/mode_test.exs`
(19 total tests, 0 failures):

| # | Scenario | Result |
|---|----------|--------|
| 1 | `:auto` — AI agent send → customer sees | ✅ `assert_receive {:chat_message, _, _}` |
| 2 | `:auto -> :takeover` — customer sees `(客服已接管对话)` notice | ✅ live Session, sender = `system://chat-router`, `body.is_takeover_notice = true` |
| 3 | `:takeover` — AI agent send → customer does NOT see | ✅ `refute_receive {:chat_message, _, _}, 200`; MessageStore row still persists |
| 4 | `:takeover` — Operator (User) send → customer DOES see | ✅ `assert_receive {:chat_message, _, _}`; `user_uri?(sender) == true` bypasses gate |
| 5 | Flip back to `:auto` — AI agent send → customer sees again | ✅ same test exercises both takeover-suppress and auto-pass-through |

Plus contract / unit coverage: `actions/0`, `state_slice/0`,
`init_slice/1`, `required_caps/0`, `cap_subjects/0`,
`Chat.reads_sibling_slices/0`, `takeover_notice_text/0`,
`invoke(:get)` happy + legacy-slice defaults, `invoke(:set)` happy
both directions + no-op + unsupported-mode rejection, no-notice on
`:takeover -> :auto` (silent reverse edge).

Umbrella regression check: 0 new failures introduced. Baseline
`apps/ezagent_domain_chat/test/` had 13 failures on
`poc/phase-2-customer-service` HEAD before this work; same 13
failures + 19 new passing Mode tests after this work (one pre-existing
`Session.behaviors/0` assertion was updated to include the new
Behavior — that update is part of this PR).

## Dispatch shape for Phase 2.7 dashboard

To flip mode from the operator dashboard (admin LV or programmatic):

```elixir
target = URI.new!("#{URI.to_string(session_uri)}?action=mode.set")

Invocation.dispatch(%Invocation{
  target: target,
  mode: :call,                    # call so the operator sees the result
  args: %{mode: :takeover},       # or :auto
  ctx: %{
    caller:  operator_user_uri,   # the operator's entity://user/... URI
    caps:    operator_caps,       # MapSet holding cap(:session, Mode, :set)
    reply:   {:caller_inbox, self()}
  }
})

# => {:ok, %{mode: :takeover, previous: :auto}}    # or
# => {:error, {:unsupported_mode, :copilot}}      # for future modes
```

Cap requirement: `cap(:session, Ezagent.Behavior.Mode, :set,
<session_uri>, <workspace_uri>)`. The dashboard subagent will need
to either (a) grant this cap to operators at session-create time
(`User.default_caps/1` extension) or (b) extend the session-owner
default-caps bundle. For Phase 2.7 the simplest path is `(b)` — Mode
caps ride session ownership (delegated to `Chat.data_owner/1` in
`Mode.data_owner/1`), so the session owner already has `grant_cap`
authority.

To read the current mode for UI rendering:

```elixir
target = URI.new!("#{URI.to_string(session_uri)}?action=mode.get")
{:ok, %{mode: current}} = Invocation.dispatch(%Invocation{
  target: target,
  mode: :call,
  args: %{},
  ctx: %{caller: caller, caps: caller_caps, reply: {:caller_inbox, self()}}
})
```

Or skip dispatch entirely and pull the slice directly via the existing
`Ezagent.Kind.get_slice/2` (dashboard LV that already has the session
open).

## Files touched

| File | Change |
|---|---|
| `apps/ezagent_domain_chat/lib/ezagent/behavior/mode.ex` | NEW — Mode Behavior |
| `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` | `reads_sibling_slices/0 == [:mode]`; takeover gate in `:send` + `agent_sender?/1` helper |
| `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` | `behaviors/0` adds `Ezagent.Behavior.Mode` |
| `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex` | `CapabilityRegistry.register(Session, :set / :get, Mode)` |
| `apps/ezagent_domain_chat/test/ezagent/entity/session_test.exs` | update behaviors/0 assertion |
| `apps/ezagent_domain_chat/test/ezagent/behavior/mode_test.exs` | NEW — 19 tests covering the 5 scenarios + contract + edges |

## Constraint adherence

- ✅ Generic primitive, not customer-service-specific. The Mode enum
  is open (`:auto`, `:takeover`, plus a documented expansion path for
  `:copilot` / other-business modes); only `:auto` + `:takeover` are
  implemented today, with `Mode.invoke(:set)` rejecting unknown modes
  via `{:error, {:unsupported_mode, _}}`.
- ✅ No `mix deps.get` run.
- ✅ Existing operator chat path untouched — `chat.send` from a User
  Kind sender passes through every gate regardless of mode.
- ✅ Notice text is byte-exact `"(客服已接管对话)"`. No translation,
  no rewording.
- ✅ Time-boxed: well under 4h.
