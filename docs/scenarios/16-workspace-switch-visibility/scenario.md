# Scenario 16: Switch workspace + visibility filter

**Category**: 6 — Cross-workspace
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-27 (PR #434 cap-based visibility merge)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- TWO workspaces: `workspace://system` (default) and `workspace://acme`
- Agents in both: `entity://agent/system/echo_1` and `entity://agent/acme/echo_a`
- Admin has caps in both workspaces (admin holds `:any`)

## Actors

- **Caller**: admin
- **Targets**: workspace dropdown + per-workspace agent list

## Steps

1. In `/admin`, observe the workspace dropdown (top-right) showing `system`.
2. Verify the agents list shows `entity://agent/system/echo_1` ONLY (workspace filter active).
3. Open the workspace dropdown; verify `acme` is visible (admin has caps in it).
4. Click `acme`; LV updates context.
5. Verify the agents list now shows `entity://agent/acme/echo_a` ONLY.
6. Sessions list, templates list, routing rules list all reflect the new workspace.
7. Switch back to `system`; verify the filter reverts.

## Expected outcomes

- LV socket assigns `current_workspace_uri` is updated on switch.
- All per-workspace queries use the new URI as a filter parameter.
- The URL may carry `?ws=<workspace_uri>` (TBD per UI impl).
- Cap check for switching is done at switch-time (admin has it; non-admin would fail unless they have a cap in the target workspace).

## Failure modes to test

- Try to switch to a workspace the user has NO caps in: dropdown should NOT show it (cap-based visibility, PR #434). If a stale URL `?ws=other` is hit, LV rejects with `:unauthorized` + redirects to default.
- Workspace destroyed while user is in it: LV detects via PubSub; redirects to a default workspace.
- Same workspace name + different ID confusion: workspace URIs are canonical per `feedback_uuid_is_canonical_identifier`.

## Cross-references

- Related PRs:
  - PR #423 — SPEC: cap-based workspace visibility
  - PR #434 — feat: cap-based visibility replaces visible field
  - PR #417 — workspace prefix invariant
- Related SPECs:
  - `docs/superpowers/specs/2026-05-27-workspace-cap-based-visibility.md`
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model.md`
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model-v2.md`
- Tests:
  - `apps/ezagent_core/test/integration/workspace_isolation_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/plugin_isolation_workspace_test.exs`
- Open bugs / gaps:
  - Multi-workspace user post-login default workspace: see scenario 17.

## Notes

- PR #434 was the structural fix: previous `workspace.visible :: bool` was replaced by "user sees a workspace iff they hold ANY cap whose `workspace_uri` matches (or is `:any`)".
- Per `feedback_north_star_plugin_isolation`, the dropdown + filter is generic; no plugin knows about it.
