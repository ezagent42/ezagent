# Admin User Management UI

Date: 2026-06-30
Branch: `feat/admin-user-management-ui-0630`
Owner: Codex

## Goal

Add the missing world/admin user-management UI so an operator can create a user,
open a user detail page, edit profile email/display name, reset password, and
soft-disable / re-enable the user from `/identities/users`.

## Context

The morning analysis found that user creation already had backend entry points
and an invite-code path, but the world UI exposed no user create/detail surface.
The expected operator path for this increment is direct admin management inside
the identities area.

## Scope

- Add `/identities/users/new` and `/identities/users/:uri` world routes.
- Add world state builders for users table, new-user form, and user detail.
- Wire React callbacks for user create, profile save, password reset, disable,
  and enable.
- Add backend soft-disable fields to users so "delete" is represented as a
  reversible account disable instead of hard deletion.
- Keep user mutations behind admin authority and existing dispatch paths where
  a Behavior already exists.

## Owned Surfaces

- `apps/ezagent_domain_identity/lib/ezagent/users.ex`
- `apps/ezagent_domain_identity/lib/ezagent/entity.ex`
- `apps/ezagent_core/priv/repo*/migrations/*disabled_fields_to_users*`
- `apps/ezagent_plugin_world/lib/ezagent/world/*`
- `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`
- `apps/ezagent_plugin_world/assets/src/main.tsx`
- `apps/ezagent_web/lib/ezagent_web/router.ex`
- `apps/ezagent_web/test/ezagent_web/world_user_admin_test.exs`

## Definition Of Done

- Admin can see a "New user" entry from `/identities/users`.
- Admin can create a user and land on `/identities/users/:uri`.
- Admin can edit display name/email and reset password from the detail page.
- Admin can disable and re-enable a user.
- Disabled users cannot authenticate; enabled users can authenticate with the
  reset password.
- Unit/integration tests cover backend disable semantics and world UI dispatch.
- Browser screenshots are saved under `docs/together/2026-06-30/tests/`.
