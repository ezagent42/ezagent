# Scenario 20: Workspace create + add member + destroy

**Category**: 8 — Workspace management
**Status**: ⚠️ implemented-with-gaps
**Last verified**: 2026-05-27 (create + add_member path; destroy E2E never run)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- A user `entity://user/system/alice` exists

## Actors

- **Caller**: admin
- **Targets**: `workspace://acme` (created), Alice (added member)

## Steps

### Create

1. Open `/admin/workspaces`; click "Create workspace".
2. Enter name `acme`; submit.
3. Verify `workspaces` row + a `workspace://acme` Kind worker is spawned.
4. The default SessionTemplate is seeded (PR #419 default + #399 system canonical fix).

### Add member

5. From `/admin/workspaces/acme`, click "Add member"; select Alice.
6. Behavior `Workspace :add_member` dispatches:
   - Validates Alice's URI carries workspace prefix `system` (PR #417 invariant)
   - Spawns the member-side state (a Kind in `acme`'s context)
   - Grants Alice baseline workspace caps (per `username-default` agent auto-create — see scenario 5 in master README §6)

### Destroy (gap)

7. Click "Destroy workspace"; confirm.
8. **Today**: this triggers `lifecycle.terminate` on the workspace Kind but does NOT cascade through child sessions / agents / member URIs. Saga compensation untested.
9. **Intended**: all child resources terminate; bindings are torn down; member URIs are evicted; finally the workspace row + Kind row are deleted.

## Expected outcomes

- Create: `workspaces` row + `kind_snapshots` row + default SessionTemplate row.
- Add member: `workspace_members` row + Alice's slice `:identity.workspaces` includes `workspace://acme`.
- Destroy: ALL child rows deleted (today: gap; tested individually).

## Failure modes to test

- Create with duplicate name: `:already_exists`.
- Add member with cross-workspace URI (`entity://user/other_ws/bob` into `acme`): rejected by PR #417 validator.
- Destroy a workspace with active sessions: today, partial destroy (leak). Phase 2's Saga (scenario 24) will fix.

## Cross-references

- Related PRs:
  - PR #417 — workspace prefix invariant
  - PR #419 — add_member spawn-then-grant + default SessionTemplate seed
  - PR #399 — revert PR #397 over-correction; `session://default/system/main` is canonical (Allen 2026-05-26)
  - PR #398 — rename `session://default/*` → `session://system/*`
- Related SPECs:
  - `docs/superpowers/specs/2026-05-25-workspace-default-to-system.md`
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model.md`
- Tests:
  - `apps/ezagent_domain_workspace/test/integration/add_member_spawn_then_grant_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/add_template_invokes_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/create_session_dispatch_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/plugin_isolation_workspace_test.exs`
  - `apps/ezagent_core/test/integration/lifecycle_terminate_test.exs` (terminate only)
- Open bugs / gaps:
  - **No destroy-cascade E2E test**. See scenario 24.

## Notes

- The destroy gap is the principal Category 8 gap. Until scenario 24 lands, destroying a non-empty workspace is operator-discouraged.
- Per PR #399, `system` is the canonical default workspace name; the historical `default` alias is forbidden. Tests should use `system`.
