# Scenario 15: Revoke cap + non-admin denial

**Category**: 5 — Capability management (CapBAC)
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-25 (PR #356 r4 + cap-cleanup PR series)

## Pre-conditions

- Scenario 14 just ran (Alice has a cap to send to `sess_a`)
- Alice is currently logged in

## Actors

- **Caller**: admin (revoking)
- **Target**: Alice (`entity://user/system/alice`)
- **Bystander**: Alice's active LV/CLI session

## Steps

### Revoke

1. As admin in `/admin/users/alice/caps`, find Alice's cap row; click "Revoke".
2. Confirm.
3. Verify the `caps` DB row is deleted (or marked revoked, depending on `caps_cleanup_v1` impl).
4. Verify Alice's `kind_snapshots` slice `:identity.caps` no longer contains the cap.

### Denial test

5. As Alice (separate browser session), navigate back to `/admin/sessions/sess_a`.
6. Try to send a message.
7. Verify the dispatch fails with `:unauthorized`; the LV flash shows "You don't have permission to send to this session".
8. Try via CLI: `EZAGENT_TOKEN=<alice_token> mix ezagent chat send --target session://system/sess_a --message "test"`.
9. Verify CLI returns the same `:unauthorized` (CLI↔LV parity).

### Audit

10. In `/admin/events` (or via SQLite `select * from invocations where target_uri = '...' order by id desc limit 5`), verify two `:authz_denied` telemetry rows: one from the LV attempt, one from the CLI attempt.

## Expected outcomes

- Revoke writes an audit row (separate from invocations, in `caps_audit` if cleanup-v1 r4 is fully impl'd).
- Allow path no longer works; deny path works.
- LV + CLI both show consistent `:unauthorized` (`feedback_test_commands_before_suggesting`).

## Failure modes to test

- Revoke while Alice is mid-dispatch (race): TOCTOU window. Today there is no per-dispatch cap re-check after the start; the in-flight dispatch completes.
- Revoke a cap that doesn't exist: `:not_found` + idempotent (admin can re-click without error).
- Revoke admin's own cap: admin role exemption (`Ezagent.Entity.User.admin_caps/0`) is structural; you cannot revoke it via the LV (it is not stored in `caps` — see Notes).

## Cross-references

- Related PRs:
  - PR #356 — User-Kind ops carve-out
  - PR #410 — Capability action axis
  - cap-cleanup-v1 SPEC + r4-impl SPEC — `docs/superpowers/specs/2026-05-25-caps-cleanup-v1*.md`
- Related SPECs:
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md`
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
- Tests:
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs`
  - `apps/ezagent_core/test/integration/non_admin_grant_flow_e2e_test.exs`
  - `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`

## Notes

- Admin's `admin_caps/0` is a **module function**, not a `caps` DB row — it cannot be revoked via the LV form. This is the structural admin-bypass.
- Per `feedback_completion_requires_invariant_test`, the cap-denial invariant test is the gate for any Phase 2 Behavior migration.
- Per `feedback_e2e_prefers_non_admin_user`, Alice is the canonical user for cap-grant E2E flows.
