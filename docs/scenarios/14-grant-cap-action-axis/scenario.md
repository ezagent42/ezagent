# Scenario 14: Grant cap via LV (action-axis)

**Category**: 5 — Capability management (CapBAC)
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-27 (PR #410 + #426 action-axis fixes)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- A non-admin user U exists: `entity://user/system/alice`
- An agent A exists: `entity://agent/system/echo_x`

## Actors

- **Caller**: admin
- **Target**: user U (`entity://user/system/alice`)
- **Capability subject**: a 5-axis cap `{kind, behavior, action, instance, workspace_uri}`

## Steps

1. Open `/admin/users/alice/caps` (or `/admin/caps?subject=alice`).
2. Click "Grant cap"; fill:
   - Kind: `Ezagent.Entity.Session`
   - Behavior: `Ezagent.Behavior.Chat`
   - Action: `:send` (action selector dropdown — see Notes for current gap)
   - Instance: `session://system/sess_a` (specific) OR `:any`
   - Workspace: `workspace://system`
3. Submit; verify a `caps` row in DB + a flash showing the new cap.
4. Login as Alice (scenario 02, but with Alice's password).
5. From `/admin/sessions/sess_a`, send "hello"; verify the dispatch succeeds (cap matches).
6. Try sending to a DIFFERENT session `session://system/sess_b`; verify `:unauthorized` (instance narrow).
7. Try `Ezagent.Behavior.Routing :add_rule`; verify `:unauthorized` (behavior + action narrow).

## Expected outcomes

- `caps` row in DB with the 5-axis cap.
- `kind_snapshots` row for U updated (caps are in slice `:identity.caps`).
- Allow path: matching dispatch succeeds.
- Deny path: non-matching dispatch fails with `:unauthorized` per `authz_check` (Invocation §5.5).

## Failure modes to test

- Grant a `:cross_workspace` cap (admin only): non-admin should see this action-selector option disabled.
- Grant a cap with `action: :any`: today admin can do this via the "admin-role exemption"; non-admin grant forms must NOT show this option (todo entry).
- Grant a cap on a non-existent kind/behavior: form should reject (compile-time check via `BehaviorRegistry`).
- Grant + revoke + grant: each operation writes a new `caps` row; revoke is a delete.

## Cross-references

- Related PRs:
  - PR #410 — feat: Capability struct gains action axis
  - PR #264 — CapabilityRegistry (original cap-needed table)
  - PR #265 — Presence cap-gate
  - PR #356 — User-Kind Behavior carve-out (cap-shape workaround)
  - PR #426 — fix: action-specific cap grants in BindingPolicy
- Related SPECs:
  - `docs/superpowers/specs/2026-05-23-capability-registry.md`
  - `docs/superpowers/specs/2026-05-27-capability-action-axis.md`
  - `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md`
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md`
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
- Tests:
  - `apps/ezagent_core/test/integration/cap_action_axis_invariant_test.exs` (THE invariant)
  - `apps/ezagent_core/test/integration/cap_action_axis_snapshot_restore_test.exs`
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs`
  - `apps/ezagent_core/test/integration/non_admin_grant_flow_e2e_test.exs`
  - `apps/ezagent_core/test/integration/routing_cap_test.exs`
  - `apps/ezagent_domain_identity/test/ezagent/behavior/identity_grant_test.exs`
- Evidence:
  - `docs/notes/caps-e2e-design.md` — why caps "felt invisible" + test design
- Open bugs / gaps (todo):
  - "Entity-caps LV grant form needs action-selector dropdown (post action-axis PR)" — current admin-role exemption bridges this; future PR adds the dropdown.
  - "Admin promotion cap-lifecycle cleanup" — temp-promotion caps survive demotion.

## Notes

- The cap struct shape is `{kind, behavior, action, instance, workspace_uri}` — 5 axes (PR #410). All 5 must match for a cap to authorize an action.
- Admin holds `%{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any}` — structural, not wildcard fallback (`feedback_let_it_crash_no_workarounds`).
- This scenario is master README §6 priority 5 — preserving action-narrow grants through Phase 2 migrations is the defining invariant.
