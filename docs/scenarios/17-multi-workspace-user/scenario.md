# Scenario 17: User with caps in multiple workspaces

**Category**: 6 — Cross-workspace
**Status**: ⚠️ implemented-with-gaps
**Last verified**: only the negative path (`workspace_isolation_test.exs`)

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
  - `apps/ezagent_core/test/integration/workspace_isolation_test.exs` — covers the negative cross-workspace dispatch path
  - No test for multi-WS user default-workspace selection at login
- Open bugs / gaps:
  - **No SPEC for default-workspace-at-login for multi-workspace users**. This is the headline gap in Category 6 and the reason scenario 04 (cross-workspace token) is downstream-blocked.
  - **Cap-grant ≠ membership** semantic: today they are independent fields. Worth aligning.

## Notes

- Per Allen 2026-05-26 (PR #399 + #398), `workspace://system` is the canonical fallback if no preference exists. Confirming this is the universal default-on-multi-WS-login is the next SPEC.
- This is the principal blocker for any production deployment with non-trivial multi-tenant structure.
