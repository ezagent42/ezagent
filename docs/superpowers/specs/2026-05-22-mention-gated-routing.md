# Mention-gated agent dispatch — the routing default

> **Status**: DRAFT rev 1 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22. Will go through `codex adversarial-review` before
> implementation.

## 0. The problem

Allen Feishu 2026-05-22: *"如果 system default 就是所有人收到所有人的
消息，mention 有什么意义？默认不应该是没有任何转发，所有人都'收不到'
所有人吗？"*

Today the `system_default` routing rule (seeded by
`EzagentDomainChat.DefaultRules.ensure_session_members_default_rule/0`
into the `MentionRouting` table) is:

```
matcher: {:always}   receivers: ["$session_members"]
```

`$session_members` expands (in `Ezagent.Routing.Resolver`) to every
member of the current session. So **every message dispatched into a
session is delivered to every member** (minus the sender).

Two things are wrong with this as the DEFAULT:

1. **`@mention` is decorative.** If every member already receives every
   message, mentioning `@A` changes nothing about routing — A would
   get the message anyway. Mention should be a routing PRIMITIVE; the
   `{:always}` default makes it a no-op.
2. **It is the engine of the cascade storm.** A session with N
   reply-capable agents: one message → `chat.receive` dispatched to
   all N → each replies → each reply fans to all N again →
   `(N-1)^k` exponential blow-up (measured in the V1 stress test:
   15 messages → 150,330 dispatches at N=10). The `{:always}` default
   is what makes every agent act on every message.

## 1. The key distinction — session STREAM vs agent DISPATCH

A `chat.send` into a session does TWO separate things. The current
`{:always}` default conflates them:

- **(a) Session stream.** `Chat.invoke(:send)` broadcasts the message
  to the PubSub topic `esr:session:<uri>:events`. This is what the
  **human / LiveView chat view** renders. A human in the session
  must see the whole conversation. This is NOT routing — it is an
  unconditional broadcast, and it stays unconditional.
- **(b) Agent dispatch.** The routing layer (`Resolver` + the
  `MentionRouting` rules) resolves receivers and dispatches
  `chat.receive` to each — which is what makes an **agent ACT**
  (process the message, possibly reply).

**The fix is narrow: only (b) becomes mention-gated. (a) is untouched.**
The human always sees everything; an agent only *acts* when addressed.

## 2. The change — `$mentions` receiver token + a mention-gated default

The `Message` struct already carries a `mentions` field
(`{:array, Ezagent.Ecto.URI}`). The routing layer already has a
`$session_members` magic receiver token. Add a sibling:

- **New receiver token `$mentions`** — in `Ezagent.Routing.Resolver`,
  expands to `message.mentions` (the entities the message explicitly
  `@`-addresses). Empty mentions → empty receiver list.

- **The `system_default` rule changes** from
  `{:always} → ["$session_members"]` to:

  ```
  matcher: {:always}   receivers: ["$mentions"]
  ```

  Still `{:always}` (every message is evaluated), but the receivers
  are now the message's mention list. A message with no mentions
  resolves to **zero receivers → zero `chat.receive` dispatches → no
  agent acts**. A message mentioning `@A` dispatches `chat.receive`
  to A only.

This makes `@mention` THE routing primitive (Allen's intent) and
structurally ends the cascade: an agent's reply only re-dispatches if
that reply itself `@`-mentions someone — a deliberate act, not an
automatic fan-out.

`$session_members` is NOT removed — it stays a valid token, so an
operator can still write an explicit broadcast rule (see §3).

## 3. Single-agent sessions + opting back into broadcast

Allen 2026-05-22: a single-agent session needs **no special handling**
— the human `@mentions` the agent like any other. There is no implicit
"the lone agent gets everything" rule.

If a session genuinely wants broadcast-to-all-members (e.g. a 1-on-1
where mentioning every turn is tedious, or a deliberate group room),
the operator **adds a routing rule** — an explicit per-session
`{:in_session, <uri>} → ["$session_members"]` rule via the existing
routing UI / `RoutingRegistry`. The `system_default` is mention-gated;
explicit rules broaden it per-session. No code special-case — "加一条
routing 的事情" (Allen).

## 4. Migration of existing sessions

The old `{:always} → $session_members` `system_default` row is already
persisted in the `MentionRouting` rule store. On the change:

- `DefaultRules` re-seeds: the `system_default` rule becomes
  `{:always} → $mentions`. `ensure_*` is idempotent today keyed on
  "has a system_default" — it must be made to RECOGNISE + REPLACE the
  old `$session_members` system_default with the new `$mentions` one
  (not skip because "a system_default already exists").
- Per-workspace / per-session rules an operator added by hand are
  untouched.
- After migration, existing sessions stop auto-broadcasting to agents
  — this is the intended behavior change. The session stream (human
  view) is unchanged, so no conversation history is lost or hidden.

## 5. Out of scope (V2 — Allen 2026-05-22: "UI 和用户体验上的改进 v2再说")

- Any `/sessions` chat UX change around mention (an `@`-autocomplete,
  a "who will receive this" affordance, a per-session "broadcast mode"
  toggle in the UI). V2.
- This SPEC is the routing MECHANICS only: the `$mentions` token, the
  default-rule change, the migration.

## 6. Verification

1. The `system_default` rule resolves to `["$mentions"]`, not
   `["$session_members"]`.
2. A message into a session with NO `@mention` → `Resolver` returns
   zero receivers → zero `chat.receive` dispatches; the session-events
   PubSub broadcast still fires (human view unaffected).
3. A message `@`-mentioning one agent → exactly that agent gets
   `chat.receive`; other member agents do not.
4. Cascade test: N echo agents in a session, a seed message with no
   mention → no storm (zero agent dispatches). A seed mentioning one
   echo agent → that agent acts; its reply, if it mentions no one,
   dispatches to no one (cascade depth 1).
5. An explicit per-session `{:in_session, uri} → $session_members`
   rule still broadcasts within that session (the opt-in path).
6. `DefaultRules` migration: a store holding the OLD
   `{:always} → $session_members` system_default ends up with the
   NEW `{:always} → $mentions` after boot.
7. The session stream / LiveView chat view shows every message
   regardless of mentions — no regression in human visibility.
