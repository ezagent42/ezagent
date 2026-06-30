# Browser Verification: Admin User Management UI

Date: 2026-06-30
Base URL: `http://world.localhost:10043`
Screenshot directory:
`docs/together/2026-06-30/tests/admin-user-management-ui/browser-verification/`

## Steps

1. Log in as the dev admin.
2. Open `/identities` and verify the overview header has a "New user" action.
3. Open `/identities/users` and verify the users table has a "New user" action.
4. Open `/identities/users/new` and create a new user.
5. Verify the app navigates to the user detail page.
6. Edit display name and email, save, reload the detail page, and verify the
   saved input values.
7. Set a new password.
8. Disable the user with a reason and verify the detail page switches to the
   disabled state.
9. Try to log in as the disabled user and verify the user remains on `/login`.
10. Re-enable the user and verify the detail page switches back to active.
11. Log in as the re-enabled user with the reset password and verify login
    succeeds.

## Evidence

- `01-users-list-new-user-entry.png` — user list and New user action.
- `02-new-user-form.png` — new user form.
- `03-created-user-detail.png` — created user detail route.
- `04-profile-edited-password-reset.png` — profile saved and password reset.
- `05-user-disabled.png` — user disabled state and Enable user action.
- `06-disabled-user-login-blocked.png` — disabled user login blocked.
- `07-user-enabled.png` — user re-enabled state.
- `08-enabled-user-login-succeeds.png` — re-enabled user login succeeds.
- `09-identities-overview-new-user-entry.png` — `/identities` overview with
  New user and New agent actions.
- `result.json` — machine-readable browser run result.
