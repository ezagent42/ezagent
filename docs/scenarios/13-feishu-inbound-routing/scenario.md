# Scenario 13: Feishu inbound message → routed to agent

**Category**: 4 — Feishu integration
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-27

## Pre-conditions

- Phx + Feishu sidecar running
- Scenario 12 setup (a binding exists for `oc_83a4f1ff0bf627ffe26aa60647e5b04a`)
- A cc / curl / echo agent is a member of the bound session
- Routing rule active so the agent receives mentions
- Feishu app webhook target is the sidecar's public URL

## Actors

- **Caller**: a Feishu user (could be Allen) sending a message in the bound chat
- **Target**: the agent that resolves from the mention or `$session_members` fan-out
- **External systems**: Feishu Open API webhook → sidecar → ezagent

## Steps

1. From the Feishu app (mobile or desktop), in the bound chat, send: `@<bot_name> hello agent`.
2. Feishu Open API POSTs the webhook to the sidecar.
3. Sidecar parses the webhook + posts a JSON-RPC `incoming_message` to ezagent.
4. `Ezagent.PluginFeishu.FeishuAdapter.receive/1` handles the message:
   - Resolves the originating user via `user_binding` table (Feishu user_id → ezagent user URI)
   - Resolves the chat → session via `inbound_chat_lookup` (`chat_id → session_uri`)
   - Validates BindingPolicy (PR #426 — action-specific cap grants)
   - Constructs an Invocation: `chat.send` against the session, `ctx.caller` = the resolved user
5. The session fan-out + mention-gated routing decides the recipient agent (scenario 10).
6. The agent processes + replies; the reply flows back via scenario 12 outbound.

## Expected outcomes

- `inbound_chat_lookup` table has `{chat_id, app_id, session_uri}` row.
- `feishu_user_bindings` table has the inbound user binding row.
- `invocations` row for `chat.send` with `ctx.caller = entity://user/.../<feishu-resolved>`.
- The Feishu user sees the agent's reply in the chat.

## Failure modes to test

- Feishu user not bound to an ezagent user: BindingPolicy decides (depending on policy: reject / auto-create / pair-prompt). See `binding_policy_test.exs`.
- Webhook signature invalid: sidecar rejects; never reaches ezagent.
- Sidecar parse error: 400 to Feishu; ezagent unaffected.
- Bound session has been destroyed: `:target_not_found`; sidecar logs the dead binding for admin cleanup.
- Bot mentioned but no agent member: PR #406 mention_failed (cross-side).

## Cross-references

- Related PRs:
  - PR #426 — fix: action-specific cap grants in BindingPolicy (§3.6.1(b))
  - PR #403 — snapshot reconcile_after_load (binding union after restore)
- Related SPECs:
  - `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  - `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
- Tests:
  - `apps/ezagent_plugin_feishu/test/inbound_chat_lookup_test.exs`
  - `apps/ezagent_plugin_feishu/test/feishu_chat_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/binding_policy_test.exs`
  - `apps/ezagent_plugin_feishu/test/user_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/behavior/user_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/webhook_attachments_test.exs`
  - `apps/ezagent_plugin_feishu/test/sender_resolver_test.exs`
  - `apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs`

## Notes

- The sidecar is the only process that holds Feishu app credentials; ezagent never sees them directly.
- Per Decision Log #298 (GLOSSARY), Feishu webhook payloads can carry non-string meta values; PR #390 documented this as a silent-drop hazard (claude TUI shape, not Feishu, but the underlying lesson applies).
- Inbound message + outbound message together = the canonical Feishu integration loop.
