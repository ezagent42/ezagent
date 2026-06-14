# Scenario 17: User with caps in multiple workspaces

**Category**: 6 — Cross-workspace
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-06-14 — scenario-level journey codified in `apps/ezagent_core/test/e2e/scenario_17_multi_workspace_user_test.exs` (4 tests, green): multi-workspace visibility, system-member cross-workspace dispatch into two workspaces with per-workspace caps, non-system denial control, and revoke-then-denied. The default-workspace-at-login question (formerly the headline gap) is **resolved + tested** — see Notes.

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Two workspaces: `workspace://system` and `workspace://acme`
- A user U with caps in BOTH workspaces (admin grants them, scenario 14, twice — once per workspace)

## Actors

- **Caller**: user U
- **Targets**: 2 workspaces

## Steps

### Login + default workspace

1. U logs in via password (scenario 02 with U's credentials).
2. LV picks a default workspace for U. **Today this is implementation-defined** — likely the first workspace in their cap set, alphabetically. SPEC not authoritative.
3. Verify the workspace dropdown shows BOTH `system` and `acme`.

### Switch

4. Switch to `acme` (scenario 16).
5. Verify U can perform an action U has caps for in `acme` (e.g. send a message in an `acme` session).

### Cross-workspace cap leak prevention

6. From `acme` context, try to dispatch against a `system` URI.
7. Verify `:cross_workspace_denied` per Invocation §5.6.
8. Switch back to `system`; verify the same action now succeeds.

### Magic-link interaction

9. U logs out + uses a magic-link from scenario 01 to re-authenticate.
10. Verify the post-magic-link default workspace selection is consistent with the password-login default. (Current implementation: NOT consistent — magic-link may default to last-active; password defaults to first-alphabetically. SPEC needed.)

## Expected outcomes

- U can switch freely between workspaces (cap-gated).
- Cross-workspace dispatch is denied per the structural cap check.
- Default workspace selection is deterministic + documented.

## Failure modes to test

- U is granted a cap, then it's revoked: the workspace disappears from the dropdown on next LV mount (PubSub-driven update).
- U is granted a cap in a workspace they were never a member of: do they get auto-added as member? Today: NO — cap grant ≠ membership. Discrepancy worth a SPEC.

## Cross-references

- Related PRs:
  - PR #417 — workspace prefix invariant
  - PR #434 — cap-based visibility
- Related SPECs:
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model-v2.md` — partial coverage
  - `docs/superpowers/specs/2026-05-25-workspace-default-to-system.md` — system as default (but not for multi-WS users)
- Tests:
  - `apps/ezagent_core/test/e2e/scenario_17_multi_workspace_user_test.exs` — the scenario-level
    journey (visibility of two memberships, system-member cross-workspace dispatch into two
    workspaces, non-system denial control, revoke-then-denied).
  - `apps/ezagent_core/test/invariants/cap_based_workspace_visibility_invariant_test.exs` —
    INV-1..8 cover the workspace-dropdown/visibility model (step 3).
  - `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs` +
    `promote_to_system_grants_cross_workspace_test.exs` — the membership-based cross-workspace
    authority predicate (steps 4-8).
  - `apps/ezagent_domain_instance_message/test/integration/workspace_isolation_test.exs` —
    the negative cross-workspace dispatch path.
  - `apps/ezagent_web/test/ezagent_web/session_principal_test.exs:147` — the default-workspace
    invariant (`current_workspace_uri == entity_workspace_uri`), enforced uniformly for all
    auth paths.
- Open bugs / gaps:
  - **Cap-grant ≠ membership** semantic: today they are independent fields (cap-scope and
    membership both contribute to visibility per INV-6). Worth aligning if a single source of
    truth is wanted, but not a correctness gap.

## Notes

- **Default-workspace-at-login is resolved (Phase 9 PR-5, SPEC v3 §6.1) — the doc's earlier
  "first-alphabetically vs last-active, not consistent, SPEC needed" was a pre-Phase-9
  description.** `EzagentWeb.SessionPrincipal.put/2,3` is the single authorized writer of
  `:current_workspace_uri`, and ALL auth paths funnel through it
  (`session_controller.ex:138` password, `magic_link_controller.ex:92` magic-link,
  `registration_controller.ex:154` registration). It always derives
  `workspace_uri = entity_workspace_uri(entity_uri)` — the user's home workspace — and enforces
  the invariant `current_workspace_uri == entity_workspace_uri(current_entity_uri)` at the write
  site (tested: `session_principal_test.exs:147`, plus `:217`/`:261` prove no other writer
  exists). So the default is deterministic AND identical across login methods. A workspace
  *switch* is logout + re-auth into the target workspace (SPEC v3 §6.4) — entity URIs are
  workspace-bound, so switching workspace is switching entity.
- Entity URIs being workspace-bound means a "multi-workspace user" reaches non-home workspaces
  either by cross-workspace authority (system membership / `:any` cap) or by re-authing into the
  target workspace — both exercised by the scenario test + the cited invariants.
