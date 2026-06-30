# Return: Admin User Management UI

returned_at: 2026-06-30T12:07:36+08:00
deadline: 2026-06-30 EOD
deadline_status: on_time
branch: `feat/admin-user-management-ui-0630`

## Summary

Implemented admin user-management in the world identities surface:

- `/identities` now links directly to the user create flow.
- `/identities/users` now links to a user create flow.
- `/identities/users/new` creates a workspace-scoped user.
- `/identities/users/:uri` manages profile, password, disable, and enable.
- Soft-disable metadata is persisted on users and blocks password/token login.
- User-specific world data was split into `Ezagent.World.UserData` so the world
  state module stays under the architecture LOC gate.
- Shared capability rendering was moved to `Ezagent.World.CapData` so the
  cross-file duplicate-function architecture gate stays at baseline.
- The PostgreSQL baseline was left unchanged; disabled-user fields are applied
  through the standalone `20260630000000_pg_add_disabled_fields_to_users`
  migration so fresh test DB rebuilds do not double-add columns.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | Admin can see a "New user" entry from `/identities` and `/identities/users`. | met | Browser screenshots `09-identities-overview-new-user-entry.png`, `01-users-list-new-user-entry.png`; `apps/ezagent_web/test/ezagent_web/world_user_admin_test.exs`. |
| 2 | Admin can create a user and land on `/identities/users/:uri`. | met | Browser screenshots `02-new-user-form.png`, `03-created-user-detail.png`; world user admin test. |
| 3 | Admin can edit display name/email and reset password from the detail page. | met | Browser screenshot `04-profile-edited-password-reset.png`; world user admin test. |
| 4 | Admin can disable and re-enable a user. | met | Browser screenshots `05-user-disabled.png`, `07-user-enabled.png`; world user admin test. |
| 5 | Disabled users cannot authenticate; enabled users can authenticate with the reset password. | met | Browser screenshots `06-disabled-user-login-blocked.png`, `08-enabled-user-login-succeeds.png`; `users_test.exs` and `entity_test.exs`. |
| 6 | Unit/integration tests cover backend disable semantics and world UI dispatch. | met | `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_user_admin_test.exs apps/ezagent_domain_identity/test/ezagent/users_test.exs apps/ezagent_domain_identity/test/ezagent/entity_test.exs --trace`. |
| 7 | Browser screenshots are saved under `docs/together/2026-06-30/tests/`. | met | `docs/together/2026-06-30/tests/admin-user-management-ui/browser-verification/`. |

**Method friction:** the handoff correctly identified the missing admin UI, but
the "delete user" wording needed an implementation decision. I implemented it
as reversible soft-disable because the existing hard delete path is used for
anon-user garbage collection and should not be exposed as an admin account
operation. The PG baseline/new migration interaction also needed a fresh
`MIX_ENV=test mix ezagent.db.reset` to catch; future DB tasks should explicitly
test fresh PG rebuilds when adding post-baseline migrations.

## Browser Evidence

Screenshots and run result:
`docs/together/2026-06-30/tests/admin-user-management-ui/browser-verification/`

The browser run created `entity://system/user/ui-admin-388202`, edited its email,
reset the password, disabled it, verified disabled login is blocked, re-enabled
it, and verified login succeeds.

## Verification

Passed:

- `MIX_ENV=test POSTGRES_PORT=5432 mix ezagent.db.reset` (fresh test PG rebuild after removing duplicate baseline field additions)
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/ezagent/uri_query/scan_test.exs apps/ezagent_core/test/mix/tasks/ezagent.uri_query.scan_test.exs --trace`
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_user_admin_test.exs --trace`
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs --trace`
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/architecture/oversized_modules_test.exs --trace`
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/architecture --trace`
- `MIX_ENV=test POSTGRES_PORT=5432 mix ezagent.arch.scan`
- `MIX_ENV=test POSTGRES_PORT=5432 mix ezagent.check_invariants`
- `MIX_ENV=test POSTGRES_PORT=5432 mix format --check-formatted`
- `npm run build` in `apps/ezagent_plugin_world/assets`
- `npm run check:mounts` in `apps/ezagent_plugin_world/assets`
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs --trace`
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_domain_identity/test/ezagent/users_test.exs apps/ezagent_domain_identity/test/ezagent/entity_test.exs --trace`
- `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs apps/ezagent_domain_socialware/test/ezagent/socialware/outbox_test.exs apps/ezagent_web/test/ezagent_web/socialware/external_feed_socket_test.exs apps/ezagent_web/test/ezagent_web/world_user_admin_test.exs apps/ezagent_domain_identity/test/ezagent/users_test.exs apps/ezagent_domain_identity/test/ezagent/entity_test.exs --trace`

Not green:

- `MIX_ENV=test POSTGRES_PORT=5432 mix precommit` was run twice. After fixing
  the fresh-PG baseline/migration collision and resetting the test DB, the
  socialware outbox missing-table failures were gone. The final run still failed
  on environment/concurrency items outside this task:
  - multiple architecture tests timed out under full umbrella `max_cases: 32`
    while running the shared `arch.scan`; the same architecture suite passed via
    `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/architecture --trace`
    and `mix ezagent.arch.scan`.
  - `apps/ezagent_core/test/integration/home_migration_test.exs` fails because
    `pg_dump` is not installed / not on PATH (`command -v pg_dump` returned
    empty).
  - `apps/ezagent_plugin_py/test/np_role_test.exs` intermittently times out in a
    real subprocess `Workspace.create_agent` call.
