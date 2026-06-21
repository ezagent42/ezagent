# Message session-scoping — collapse vestigial multi-routing — design

> Status: design (Allen 2026-06-21). Prerequisite for the anon→login merge (dissolves its B3).
> Standalone value: simpler model, faster reads (no join), removes dead Phase-3 infra.

## 1. Problem
`messages` is a global row (1 per `message_id`, Decision #40 identity invariant) + a
`message_routings` join (1 row per `(message_id, session_uri)`) added in Phase 3 D8 to let the SAME
`message_id` appear in multiple sessions. **Verified 2026-06-21: multi-routing is vestigial** — every
`MessageStore.write/2` site (`turn.ex:604`, `session.ex:416`, feishu adapter) writes to exactly ONE
session; cross-session forwarding is `{:dispatch, %Cmd{}}` → the target session writes its OWN new
message with `ref_id` (`session.ex:65`), NOT shared-id routing. So no live path ever puts one
`message_id` in >1 session.

Allen's architectural call: messages SHOULD be session-scoped; cross-session = **copy as a new
message in the target session (+ `ref_id` for navigation)** — which is already how forwarding works.

## 2. Goal
Collapse to session-scoped messages: a message belongs to exactly one session. Keep Decision #40
(one id per message — now naturally one session). Keep `ref_id` cross-session navigation (forwarding
unchanged). Remove the `message_routings` indirection.

## 3. Approach
- **Schema**: `messages.session_uri` (already present, set on first write) becomes the canonical
  per-session key. Drop the `message_routings` table (or stop writing/reading it; migrate any data —
  in practice 1:1 already). Add an index on `(session_uri, inserted_at)` for the read paths.
- **`MessageStore.write/2`**: just insert the message with `session_uri` (no routing-row insert).
- **Read queries** (`recent_in_session/2`, `in_session_since/2`, `chat_visible_recent/2`,
  `committed_customer_visible*`): replace the `JOIN message_routings` with `WHERE session_uri == ?`
  (faster, no join).
- **`sessions_for_message/1`** (uploads_controller download-auth): becomes "the message's single
  `session_uri`" (returns `[session_uri]`). Update the caller (`uploads_controller.ex:152`) — its
  `flat_map` over sessions still works with a 1-element list.
- **`by_id/1`**, `ref_id` chains: unchanged (a message still has one canonical id; ref_id still
  references another message id for forwarding navigation).
- **Migration**: a data migration that, if any `message_routings` row's `session_uri` differs from
  its `messages.session_uri` (shouldn't exist given vestigial), splits it into a copy — but assert
  the count is 0 first (fail-loud if a real multi-routed message exists, contradicting the audit).

## 4. Forwarding stays copy+ref (no regression)
Cross-session forwarding already creates a NEW message in the target session carrying `ref_id` (the
original's id) — `session.ex:65` dispatch + the relayer pattern (`message.ex` doc: "中转者只创建携带
ref_id 的新 Message"). Session-scoping does NOT change this; it just removes the unused "same id in
two sessions" capability.

## 5. Risks / verification
- **Hidden multi-routed data**: the migration asserts 0 cross-session-divergent routing rows before
  dropping the table (fail-loud if the vestigial assumption is wrong on a real DB).
- **Decision #40**: still holds (one id per message). Document the amendment: "#40 identity is now
  session-scoped; cross-session reference is `ref_id`, not shared id."
- **Query parity**: each rewritten query must return identical results to the join version on a
  single-routed DB (which is all of them) — test before/after.
- Full gate suite + the existing message/chat tests green.

## 6. Why this is PR-1 (before anon-merge)
The anon-merge's `MessageStore.relabel_identity` rewrites a message's `mentions` "within the session".
On the global+routing model that could corrupt other sessions sharing the id (B3). Session-scoping
makes the message row belong to one session → relabel is safe → B3 dissolved. So this lands first.

## 7. Cross-references
- Enables: `2026-06-21-anon-login-merge-FINAL-design.md` (B3).
- Touch points: `apps/ezagent_core/lib/ezagent/message_store.ex`, `message.ex`, `message_routing.ex`
  (remove), `apps/ezagent_web/lib/ezagent_web/controllers/uploads_controller.ex:152`, the migration.
