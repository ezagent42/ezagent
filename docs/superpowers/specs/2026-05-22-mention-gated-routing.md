# Mention-gated agent dispatch — the routing default

> **Status**: DRAFT rev 2 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22.
>
> - **rev 1**: initial design.
> - **rev 2**: `codex adversarial-review` — 1 CRITICAL + 3 HIGH.
>   `$mentions` validated; the per-USER notification path preserved
>   via `$session_users`; routing-UI broadcast option; migration.
> - **rev 3**: second `codex adversarial-review` — 2 HIGH + 1 MEDIUM.
>   (a) `$session_users` was NOT workspace-validated — a cross-workspace
>   user can land in `slice.members` via programmatic `chat.join` /
>   template instantiation → it would leak every message cross-tenant.
>   rev 3: BOTH `$mentions` AND `$session_users` apply the same
>   workspace+valid-member predicate. (b) the duplicate-`system_default`
>   migration could resurrect an admin-disabled default → rev 3:
>   disabled-wins (if ANY system_default row is disabled, the survivor
>   stays disabled). (c) silent no-op risk — plain-text "hi cc-builder"
>   sends no longer actuate; rev 3 adds a real-composer V1 test +
>   mandates the runbook/demo-doc update.

## 0. The problem

Allen Feishu 2026-05-22: *"如果 system default 就是所有人收到所有人的
消息，mention 有什么意义？默认不应该是没有任何转发，所有人都'收不到'
所有人吗？"*

Today the `system_default` routing rule (seeded by
`EzagentDomainInstanceMessage.DefaultRules.ensure_session_members_default_rule/0`
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
   get the message anyway. Mention should be a routing PRIMITIVE.
2. **It is the engine of the cascade storm.** A session with N
   reply-capable agents: one message → `chat.receive` dispatched to
   all N → each replies → each reply fans to all N again →
   `(N-1)^k` exponential blow-up (V1 stress test: 15 messages →
   150,330 dispatches at N=10). The `{:always}` default makes every
   agent act on every message.

## 1. THREE things a message does — not two (codex rev 2 — HIGH-b)

rev 1 said "stream vs dispatch". The code actually has THREE
message-fan-out paths; the `{:always}` default drives all three:

- **(a) Session stream.** `Chat.invoke(:send)` broadcasts to PubSub
  `esr:session:<uri>:events` — the **human / LiveView chat view**.
  Unconditional, NOT routing. Stays unconditional.
- **(b) Per-user notification.** When routing delivers `chat.receive`
  to a **`Ezagent.Entity.User`** member, `Chat.invoke(:receive)`
  broadcasts `{:message_received, msg}` to `esr:user:<uri>:events` —
  that user's **personal notification** (inbox/badge), a separate
  topic from the session stream. `chat_test.exs` asserts this.
- **(c) Agent actuation.** When routing delivers `chat.receive` to an
  **Agent** member, the agent **ACTS** (processes, maybe replies).

Allen wants only **(c)** gated. (a) is untouched. **(b) must be
preserved** — a User member who is not `@`-mentioned must still get
their personal notification (rev-1 missed this; it would have
silently dropped user notifications).

So the rule: **all User members are always recipients; Agent members
are recipients only when validly mentioned.**

## 2. The change — two receiver tokens, a mention-gated default

`Ezagent.Routing.Resolver` already has the `$session_members` magic
receiver token. Add two more — **both built on ONE validation
predicate** (codex rev 3 — HIGH-a: the session member set is NOT a
trust boundary; `chat.join` accepts any live `member_uri` and template
instantiation joins configured URIs with `admin_caps`, so a
cross-workspace entity can sit in `slice.members`).

**`valid_member?/2`** — the shared trust boundary. A candidate
receiver URI is a valid recipient iff: it parses as a well-formed
`entity://`/`session://` URI; its workspace segment equals the
current session's workspace; AND it is a currently-registered member
of the session. Anything failing — cross-workspace, cross-session,
non-member, malformed — is **dropped**.

- **`$session_users`** — `User`-Kind members of the current session,
  **filtered through `valid_member?/2`**. (Drives per-user
  notification — §1(b).) NOT the raw `slice.members` user list.
- **`$mentions`** — `message.mentions`, **filtered through
  `valid_member?/2`**. (`message.mentions` is user-controlled —
  populated from raw compose text in LiveView, from a global
  `KindRegistry.list_all/0` scan in Feishu — and `chat.receive`
  dispatches with `User.admin_caps()`; raw mentions as receivers
  would let a sender drive system-cap delivery outside the session /
  workspace.)

Both tokens go through the same predicate — the member set alone is
not trusted; workspace containment is the boundary.

The `system_default` rule changes from
`{:always} → ["$session_members"]` to:

```
matcher: {:always}   receivers: ["$session_users", "$mentions"]
```

Net effect, per message:
- every **User** member → `chat.receive` (personal notification kept);
- every **validly-mentioned** member (agents in practice) →
  `chat.receive` (the agent acts);
- an un-mentioned **Agent** → nothing. No storm.

`@mention` becomes THE routing primitive for agents (Allen's intent);
the cascade ends structurally — an agent's reply re-dispatches only if
that reply itself validly `@`-mentions a member.

`$session_members` is NOT removed — it remains a valid token for an
explicit broadcast rule (§3).

## 3. Single-agent sessions + opting back into broadcast (codex rev 2 — HIGH-c)

Allen 2026-05-22: a single-agent session needs **no special handling**
— the human `@mentions` the agent like any other; no implicit "lone
agent gets everything".

A session that genuinely wants broadcast-to-all-agents adds an
explicit per-session rule resolving to `$session_members`. rev 1 said
"add it via the existing routing UI" — but the routing UI's receiver
field is a `uri_picker` whose `UriOptions.valid_for?/4` rejects a
magic token (`$session_members` is not a URI). So the opt-in was not
actually reachable.

**rev 2**: the routing UI's receiver input gets a **first-class
"All session members (broadcast)" option** — a named choice in the
picker that the form maps to the `$session_members` token. The
operator never types a raw `$`-token; the validator special-cases the
known magic tokens (`$session_members`, `$session_users`, `$mentions`)
as valid receivers alongside concrete URIs. (UI polish beyond exposing
this one option is V2 — §5.)

## 4. Migration of existing `system_default` rows (codex rev 2 — HIGH-d)

The old `{:always} → ["$session_members"]` `system_default` row is
persisted in the `MentionRouting` rule store. Hazards in a naive
re-seed:
- `RuleStore.has_system_default?/1` returns true for any
  `source == "system_default"` row **regardless of `enabled`** — so
  the rev-1 "skip if a system_default exists" idempotency would skip
  even when only a DISABLED old row exists.
- An admin may have intentionally **disabled** the system_default.
- There may be duplicate system_default rows.

**rev 2 — explicit migration** in `DefaultRules`:
1. Find the system_default row(s). If one matches the OLD
   `{:always} → ["$session_members"]` shape, **replace its receivers**
   with `["$session_users", "$mentions"]` in place — **preserving its
   `enabled` flag** (an admin-disabled default stays disabled; do not
   resurrect it).
2. If multiple system_default rows exist: **disabled-wins** (codex
   rev 3 — HIGH-b). If ANY of the duplicate system_default rows is
   `enabled: false`, the single surviving migrated row is
   `enabled: false` — an admin's disable is never lost to a dedupe.
   Keep one row deterministically (oldest by insert order), set its
   `enabled` to the AND of all duplicates' `enabled`, migrate its
   receivers, delete the rest — log the dedupe.
3. If NO system_default row exists, seed the new
   `{:always} → ["$session_users", "$mentions"]` (enabled).
4. Reload the registry from the store.
This is a one-time data migration; it has its own tests (§6.6).

## 5. Out of scope (V2 — Allen 2026-05-22: "UI 和用户体验上的改进 v2再说")

- `/sessions` chat UX around mention: `@`-autocomplete, a "who will
  receive this" affordance, a per-session "broadcast mode" toggle. V2.
- This SPEC is the routing MECHANICS + the ONE UI addition needed to
  make the opt-in reachable (§3): the `$mentions` / `$session_users`
  tokens, the default-rule change, the magic-token-valid-receiver
  support, the migration.

## 6. Verification

1. The migrated `system_default` rule resolves to
   `["$session_users", "$mentions"]`.
2. A message into a session with NO `@mention`: every **User** member
   still gets `chat.receive` + the `esr:user:<uri>:events`
   notification; every **Agent** member gets nothing; the
   `esr:session:<uri>:events` stream broadcast still fires.
3. A message `@`-mentioning one agent → exactly that agent gets
   `chat.receive`; other member agents do not; users still all do.
4. **Trust boundary (`valid_member?/2`)** — a `$mentions` OR
   `$session_users` candidate that is (a) a non-member, (b) a
   cross-workspace URI, (c) a different session's URI, (d) malformed
   → dropped; no `chat.receive` outside the session's validated
   members. **Incl. the cross-workspace case for `$session_users`**:
   a cross-workspace User placed in `slice.members` programmatically
   (via `chat.join` / template instantiation) receives NOTHING. A
   dedicated test per case, for BOTH tokens.
5. Cascade test: N echo agents, a seed with no mention → zero agent
   dispatches; a seed mentioning one echo agent → that agent acts;
   its reply mentioning no one → cascade depth 1, stops.
6. Migration: OLD `{:always} → $session_members` enabled → migrated
   to `{:always} → [$session_users, $mentions]`, enabled. OLD row
   DISABLED → migrated receivers, still disabled. **Mixed
   enabled/disabled duplicates → the survivor is disabled
   (disabled-wins)** — a dedicated test.
7. The routing UI: the receiver picker offers "All session members
   (broadcast)"; submitting it persists a rule with the
   `$session_members` token; the validator accepts the three magic
   tokens as receivers; a global AND a session-scoped rule can both
   be created this way.
8. The session stream / LiveView chat view shows every message
   regardless of mentions — no regression in human visibility.
9. **Real-composer path (codex rev 3 — MEDIUM-c)** — a test that
   sends through the ACTUAL LiveView composer using the mention
   autocomplete (not a synthetic `message.mentions`) and verifies the
   mentioned agent gets `chat.receive`. This proves the
   compose→`Message.mentions` path actually populates mentions so the
   new default is not a silent no-op on the real surface.
10. The runbook / demo docs are updated: plain agent-name text
    ("hi cc-builder") no longer actuates an agent — only an
    `@`-mention does. Any V1 demo script that relied on plain-name
    actuation is corrected.
