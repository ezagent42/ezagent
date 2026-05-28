# Scenario 01: Magic-link email login

**Category**: 1 — Auth / Identity
**Status**: ⚠️ implemented-with-gaps
**Last verified**: 2026-05-21 (Allen, Phase 9 demo)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Mailer dev backend captures sent mail (`Swoosh.Adapters.Local`); inbox at `/dev/mailbox`
- Email transport in dev: messages appear in the Phoenix inbox UI, not real SMTP
- A user exists with a verified email; default seed is admin (`entity://user/system/admin`)

## Actors

- **Caller**: anonymous browser session
- **Target**: `entity://user/<workspace>/<username>` (e.g. `entity://user/system/admin`)
- **External systems**: Mailer (Swoosh local adapter in dev)

## Steps

1. Open `http://100.64.0.27:10042/login` in agent-browser (headless Chrome).
2. Enter the user's email in the magic-link field; click "Send link".
3. Open `http://100.64.0.27:10042/dev/mailbox` in a second tab; click the most-recent message.
4. Extract the magic-link URL from the email body (`/auth/magic/<token>`).
5. Visit the URL in the original tab.
6. Verify the LV redirects to `/admin` and the session is authenticated as the target user.

## Expected outcomes

- `users.last_login_at` is updated.
- An `invocations` row with `behavior=Ezagent.Behavior.Identity action=:magic_link_login` is written.
- The browser session carries `user_uri` in the LV socket assigns.
- Subsequent navigation to `/admin/sessions/...` succeeds (the LV mounts).

## Failure modes to test

- Magic-link token expired (>15 min): expect "Link expired" flash + redirect to `/login`.
- Magic-link token reused: expect "Link already consumed" flash. (Currently NOT enforced — see Notes.)
- Email not registered: expect a generic "If the email exists, a link was sent" message (no enumeration).

## Cross-references

- Related PRs:
  - none directly; controller dates to Phase 1
- Related SPECs: none — magic-link predates the SPEC discipline
- Tests:
  - `apps/ezagent_web/test/integration/magic_link_invariants_test.exs` — covers token generation + expiry only
- Open bugs / gaps:
  - Magic-link reuse is NOT prevented (token re-used inside expiry window logs the user in again). Worth a unit test + a one-shot-token enforcement.
  - Cross-workspace magic-link (which workspace to default to post-login) is unspecified for multi-workspace users. See scenario 17.

## Notes

- Dev-only Swoosh local adapter; in production this needs SES/Resend wiring (no SPEC yet).
- `feedback_uuid_is_canonical_identifier`: the magic-link token references the user UUID, not the username.
- This scenario is marked ⚠️ because the reuse + multi-workspace gaps are not codified as tests.
