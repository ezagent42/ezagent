# Scenario 02: Password login — admin

**Category**: 1 — Auth / Identity
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-21 (Allen, Phase 9 demo screenshot)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Default admin user seeded: `entity://system/user/admin` with password `8bdemo`
- Dev seed runs on first boot via `EzagentCore.Bootstrap` (see `mix ezagent.bootstrap`)

## Actors

- **Caller**: anonymous browser session
- **Target**: `entity://system/user/admin`

## Steps

1. Open `http://100.64.0.27:10042/login` in agent-browser.
2. Enter username `admin`, workspace `system`, password `8bdemo`.
3. Click "Sign in".
4. Verify the LV redirects to `/admin`.
5. Verify the workspace dropdown (top-right) shows `system` selected.
6. Take an agent-browser screenshot of `/admin` showing the workspace + chat panel.

## Expected outcomes

- The LV session has `assigns.current_user.uri == entity://system/user/admin`.
- The LV session has `assigns.current_user.caps` containing `admin_caps()` (5-axis `:any`).
- A telemetry event `[:ezagent, :auth, :login_succeeded]` is emitted.
- `users.last_login_at` is updated.

## Failure modes to test

- Wrong password (3 attempts): no lockout today (intentional in dev; production would need rate-limiting).
- Wrong workspace name: "User not found in workspace 'foo'".
- Missing workspace field: form re-renders with validation error.

## Cross-references

- Related PRs:
  - PR #356 — `Behavior.WorkspaceUserAdmin :create_user` (separate Behavior carve-out per cap-shape limitation)
  - PR #389 — api-keys flipped from User to Agent Kind (cleared confusion about which Kind holds login state)
- Related SPECs:
  - `docs/superpowers/specs/2026-05-20-username-and-auth-design.md`
- Tests:
  - `apps/ezagent_web/test/integration/magic_link_invariants_test.exs` (covers Identity Behavior shape)
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs` (covers post-login cap behavior)
- Evidence:
  - `docs/notes/phase-9-demo-2026-05-21.md` — screenshots of admin login + admin dashboard

## Notes

- Admin cap is structural (5-axis `:any`), not a wildcard fallback — see `feedback_let_it_crash_no_workarounds`.
- Username is mutable display-only per `feedback_uuid_is_canonical_identifier`; the LV resolves username → UUID at login time.
- Per `feedback_e2e_prefers_non_admin_user`, the canonical e2e for cap-grant flows uses a non-admin user — admin login is a setup precondition, not the unit under test.
