# Browser Verification: Session Invite Entity Search

Date: 2026-06-30

## Scope

- AM-2 invite picker verification:
  - Open a session conversation in the world UI.
  - Open the members-panel invite form.
  - Search for an entity by typing a segment instead of pasting a full URI.
  - Select the result and submit invite.
  - Confirm the member appears in the session.
  - Search the same entity again and confirm the result is disabled with
    `Already in session`.

## Evidence

- `01-register-self-registration.png`
- `02-identities-no-user-create.png`
- `03-session-created.png`
- `04-invite-picker-results.png`
- `05-invite-after-submit.png`
- `06-invite-existing-member-disabled.png`
- `07-current-invite-picker-e2e-test-result.png`
- `08-current-invite-after-e2e-test-submit.png`
- `09-current-invite-existing-member-disabled.png`
- `browser-results.json`

## Notes

- Browser base URL used: `http://world.localhost:10042`.
- `127.0.0.1:10042/identities` is not valid for this route group in dev because
  world routes are host-scoped to `world.*`.
- Current re-verification invitee: `entity://system/agent/e2e-test`.
- Current re-verification session: `session://system/default/e2e-auto`.
- Current re-verification was run from branch
  `feat/session-invite-entity-search-0630` on `http://world.localhost:10042`.
