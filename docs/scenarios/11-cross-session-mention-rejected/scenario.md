# Scenario 11: Cross-session @-mention is rejected

**Category**: 3 — Session flows
**Status**: ⚠️ implemented-with-gaps
**Last verified**: never as a codified scenario (rule enforced implicitly)

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
  - No dedicated test for cross-session mention rejection. `mention_gated_routing_test.exs` covers in-session mentions only.
- Open bugs / gaps:
  - **No regression test for cross-session leak prevention**. This is a security-property; should add an invariant test asserting "agent not in session never receives a chat.receive invocation from that session".

## Notes

- The routing resolver evaluates `$session_members` per-session at dispatch time; this naturally prevents cross-session leaks but is not asserted as an invariant.
- The ⚠️ status reflects: production behavior is correct, but the codified scenario + invariant test do not exist.
- Adding this scenario before Phase 2 migrates `Chat.Behavior` to the new `action/3` macro is recommended — see master README §6 secondary investments.
