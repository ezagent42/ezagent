# PR #143 — Feishu re-shape (delete `feishu://` scheme)

Per SPEC v2 §5.8 — plugins MUST NOT own a top-level scheme. `feishu://oc_xxx` Kind is deleted; FeishuReceive Behavior moves to Session Kind (per-room) and an outbound side-channel registers per-user.

## Survey (post-PR-#141)

Files touching `feishu://`:
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex` (~273 LOC) — spawns `feishu://oc_xxx` Receiver Kind on webhook
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex` (~80 LOC) — resolves `feishu://` URI from chat_id
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/binding_policy.ex` (~125 LOC) — grants caps via `feishu://` URI
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_receive.ex` (~214 LOC) — the Receiver Behavior (moves to Session)
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding.ex` — UserBinding schema (stays — join table is fine)

## Target shape (SPEC §5.8)

### Inbound (Feishu webhook → Ezagent)

Webhook arrives with `chat_id: oc_xxx, sender_open_id: ou_yyy, message: ...`.

Pipeline:
1. Resolve `sender_open_id` → `entity://user/<name>` via `FeishuUserBinding.find_by_open_id/1`
2. Resolve `chat_id` → `session://<template>/<name>` via a new `FeishuSessionBinding` lookup (today this binding is implicit; PR #143 makes it explicit)
3. Dispatch `Ezagent.Invocation`: `target = session://<template>/<name>/behavior/chat/send` (still path-style; query string is PR #146), `args = %{message: %Message{sender: <user_uri>, ...}}`, `ctx.caller = <user_uri>`
4. Done — message lands in the session's normal chat pipeline

The `feishu://oc_xxx` Receiver Kind goes away entirely. Inbound dispatcher writes directly to the session.

### Outbound (Ezagent → Feishu)

A Behavior on Session Kind, registered by feishu plugin: `Behavior.FeishuOutbound` with action `:send_to_feishu`. When chat fan-out hits a session that has a feishu binding, the resolver dispatches to that session's `feishu_outbound/send_to_feishu` action, which calls the Feishu API.

Or simpler: outbound is a side-channel on the session's `Behavior.Chat.invoke(:send)` — when the message reaches the session, the session's slice carries `feishu_binding: <chat_id>` and the Chat Behavior emits to Feishu if bound.

The cleaner pattern: register `Behavior.FeishuOutbound` on Session Kind with `:notify` action; the chat fan-out resolver invokes `:notify` for every chat send on a session that has the feishu binding.

### Data shape

`feishu_user_bindings` table stays. Add new `feishu_session_bindings` table:

```sql
CREATE TABLE feishu_session_bindings (
  chat_id TEXT PRIMARY KEY,
  session_uri TEXT NOT NULL,
  created_at TEXT NOT NULL,
  enabled INTEGER DEFAULT 1
);
```

Migrate existing implicit bindings (today the dispatcher creates `feishu://oc_xxx` Kinds per chat_id; reconstruct the chat_id → session_uri map from those Kinds' state).

## Verification

- Send a message from Feishu → lands in the bound session, appears in /admin chat stream
- Send a message from /admin → reaches the Feishu chat (when feishu binding is configured)
- `KindRegistry` no longer has any `feishu://` entries after restart
- `Ezagent.URI.@known_schemes` removes `feishu`; `parse!/1` rejects `feishu://X`

## Scope (this PR only)

DO:
- Delete `feishu://` scheme registration from SpawnRegistry
- Delete `Ezagent.URI.@known_schemes` entry `feishu`
- Delete `FeishuReceive` Receiver Kind module
- Move FeishuReceive Behavior actions to Session Kind via new Behavior module
- Add `feishu_session_bindings` table + binding migration
- Update inbound_dispatcher to dispatch directly to `session://X/behavior/chat/send`
- Update sender_resolver to return session URIs (not feishu:// URIs)
- Update binding_policy to grant caps on the session, not on feishu://
- Migration to delete `feishu://` rows from kind_snapshots + routing_rules
- Tests updated

DO NOT:
- Touch routing-admin / pty-input (PR #144)
- Touch query-string action syntax (PR #146)

## Estimated effort

Significant feishu plugin refactor — 8 files touched, schema change. Subagent ~60-120 min.
