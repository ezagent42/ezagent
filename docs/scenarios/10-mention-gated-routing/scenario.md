# Scenario 10: @-mention dispatch — mention-gated routing

**Category**: 3 — Session flows
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-26 (PR #406 + PR #422)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- A session with multiple members: admin + 2 agents (e.g. `entity://agent/system/echo_1` + `entity://agent/system/echo_2`)
- Default routing rule active: `always() → ["$session_members"]` (system-default, admin-disable-only)

## Actors

- **Caller**: admin
- **Target**: a specific agent named in the mention
- **Bystander**: the other agent NOT mentioned
- **Behavior**: `Ezagent.Behavior.Chat`, action `:send` (mention parser + routing resolver)

## Steps

1. In `/admin/sessions/<session-uri>`, send: `@echo_1 hello only you`.
2. Verify the mention parser identifies `@echo_1` as a mention; the routing resolver narrows recipients to `[entity://agent/system/echo_1]`.
3. Verify `echo_1` echoes back.
4. Verify `echo_2` does NOT receive the message (no `chat.receive` invocation row for it).
5. Send a non-mention: `hello everyone`.
6. Verify BOTH `echo_1` and `echo_2` receive (the system default `always → $session_members` rule fans out).

## Expected outcomes

- For the mention message: 1 `chat.receive` invocation (only `echo_1`).
- For the non-mention: 2 `chat.receive` invocations (both echos).
- `Ezagent.Routing.MentionParser` extracts `@echo_1` correctly (URI suffix + workspace-prefix-aware).
- No `mention_failed` notification (the mention resolves).

## Failure modes to test

- `@nonexistent-agent`: PR #406 fires `mention_failed` notification to admin; the message is NOT delivered to anyone.
- `@echo_1 @echo_2 hi`: both mentioned → both receive, but no fan-out to other members (mention-gated).
- Mention with leading whitespace `   @echo_1`: parser still resolves.
- Mention in code block: parser SHOULD skip mentions inside backticks (TBD — current parser does NOT).

## Cross-references

- Related PRs:
  - PR #406 — mention_failed notification for dropped @-mentions
  - PR #422 — chore: repair umbrella-wide baseline (includes mention-routing fixes)
- Related SPECs:
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
- Tests:
  - `apps/ezagent_core/test/integration/mention_gated_routing_test.exs`
  - `apps/ezagent_plugin_feishu/test/mention_parser_test.exs` (Feishu-side parser; ezagent-side parser tested in chat tests)
- Open bugs / gaps:
  - Mentions inside code blocks / quotes / mid-word are not deduped per `MentionParser` test coverage.

## Notes

- The system-default `always → $session_members` rule is what makes "non-mention" messages fan out; it is admin-disable-only, never deletable (PR #120, Decision #120).
- Per Decision #80 (`#80-#82`) and SPEC `2026-05-22-mention-gated-routing.md` (now in `superpowers/specs/`), mention-gating is the **default** behavior on top of the system default rule.
