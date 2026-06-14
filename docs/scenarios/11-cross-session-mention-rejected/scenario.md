# Scenario 11: Cross-session @-mention is rejected

**Category**: 3 — Session flows
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-06-14 — the core cross-session-leak invariant is codified in `apps/ezagent_domain_instance_message/test/e2e/category_10_scenarios_10_11_mention_routing_test.exs`, describe `"Scenario 11 — cross-session mention rejected"` (4 tests, green). The `mention_failed` notification piece (step 5) is covered separately by PR #406 (`mention_failed_notification`, cited in scenario 10).

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- Two sessions in the same workspace: `session://system/sess_a` and `session://system/sess_b`
- Agent `entity://agent/system/echo_x` is a member of `sess_a` but NOT `sess_b`

## Actors

- **Caller**: admin (in `sess_b`)
- **Target**: `echo_x` (NOT a member of `sess_b`)

## Steps

1. Open `/admin/sessions/sess_b`.
2. Send: `@echo_x hello from b`.
3. Verify the routing resolver excludes `echo_x` from recipients (it is not in `$session_members` of `sess_b`).
4. Verify `echo_x` does NOT receive a `chat.receive` invocation.
5. Per PR #406, admin should see a `mention_failed` notification: "@echo_x is not a member of this session".

## Expected outcomes

- 0 `chat.receive` invocations for `echo_x` (no cross-session leak).
- `mention_failed` notification visible in `sess_b` LV.
- An audit-trail entry showing the mention attempt + the routing-decision rejection.

## Failure modes to test

- `echo_x` is a member of BOTH sessions: mention IS delivered (this is the happy path; not a failure).
- Admin manually adds `echo_x` to `sess_b` first, then mentions: delivery succeeds; this is the explicit-allow path.

## Cross-references

- Related PRs:
  - PR #406 — mention_failed notification
  - PR #120 (Decision #120) — `$session_members` magic receptor token
- Related SPECs:
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  - (Cross-session leak prevention is implicit in the routing resolver design)
- Tests:
  - `apps/ezagent_domain_instance_message/test/e2e/category_10_scenarios_10_11_mention_routing_test.exs`,
    describe `"Scenario 11 — cross-session mention rejected"` (4 tests, green 2026-06-14):
    - mentioning an agent NOT in the current session's members → 0 recipients (the leak guard);
    - positive control: an in-session mention DOES deliver;
    - a cross-workspace member URI in `$mentions` is dropped;
    - a session URI in `$mentions` (cross-session route) is dropped.
  - `mention_gated_routing_test.exs` covers the in-session mention happy path.
- Open bugs / gaps:
  - The `mention_failed` notification (step 5) is exercised via PR #406's `mention_failed_notification` test (cited under scenario 10), not in this routing-resolver test.
  - The audit-trail entry (expected outcome 3) has no dedicated assertion yet.

## Notes

- The routing resolver evaluates `$session_members` per-session at dispatch time; this naturally prevents cross-session leaks and is now asserted as an invariant (see Tests).
- This security invariant is a load-bearing regression guard for the socialware 基座化 (im→session→agent) split: the cross-session leak guard lives in the session-domain routing resolver, so it must stay green as routing/resolver code relocates during PR-9a/9b.
