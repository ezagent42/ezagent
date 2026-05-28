# Scenario 03: Token-based CLI auth — mint / list / revoke

**Category**: 1 — Auth / Identity
**Status**: ⚠️ implemented-with-gaps
**Last verified**: 2026-05-26 (PR #386 rebrand smoke)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Operator logged in as admin in LV (scenario 02)
- `mix ezagent` CLI available (post-PR #386 rebrand from `mix esr`)
- `EZAGENT_HOME=~/.ezagent` set (or default)

## Actors

- **Caller (LV minting)**: admin (`entity://user/system/admin`)
- **Caller (CLI dispatch)**: an end-user agent holding the minted token
- **Target**: `entity://user/<workspace>/<username>` — token's subject
- **Behavior**: `Ezagent.Behavior.UserTokens` (`:mint_token`, `:list_tokens`, `:revoke_token`)

## Steps

### Mint

1. In LV at `/admin/users/<username>/tokens`, click "Mint token".
2. Provide label "ci-runner-2026"; click submit.
3. Capture the plaintext token from the one-time flash (it is NEVER stored in plaintext server-side).
4. Save the token to a CLI-accessible location (e.g. `~/.ezagent/token`).

### Use

5. From a separate shell:
   ```
   EZAGENT_TOKEN=<token> mix ezagent identity list_api_keys --user entity://user/system/admin
   ```
6. Verify the CLI hits the SAME BEAM via distributed Erlang RPC (per Decision #130 — CLI must not boot its own VM).
7. Verify the response prints the masked api-keys list.

### List + revoke

8. In LV at `/admin/users/<username>/tokens`, observe the token row with label "ci-runner-2026", last-used timestamp updated.
9. Click "Revoke"; confirm.
10. Re-run step 5 with the same token; verify the CLI returns `:unauthorized`.

## Expected outcomes

- `user_tokens` row exists post-mint, deleted (or marked revoked) post-revoke.
- `invocations` row for each step with `behavior=Ezagent.Behavior.UserTokens`.
- CLI `--user` URI flows through `EzagentCli.Dispatch.build_target_uri/5` to the same Invocation shape an LV mount would build (CLI↔LV parity per `cli_lv_same_server_invariant_test.exs`).

## Failure modes to test

- Revoked token: `:unauthorized` (verified in step 10).
- Token used in a workspace the user does not have caps in: `:cross_workspace_denied`.
- Token used for an action the user lacks the cap for: `:unauthorized` (post-PR #410 action-axis).
- In-flight CLI dispatch when token revoked mid-call: **not currently invalidated** — see Notes.

## Cross-references

- Related PRs:
  - PR #356 — User-Kind ops carved into `WorkspaceUserAdmin` Behavior (cap-shape limitation workaround)
  - PR #386 — `mix esr` → `mix ezagent` rebrand
  - PR #410 — Capability action axis
  - PR #438 — URI canonicalization (CLI passes full `entity://...` URIs through)
- Related SPECs:
  - `2026-05-20-username-and-auth-design.md`
  - `2026-05-27-uri-canonicalization.md`
- Tests:
  - `apps/ezagent_cli/test/integration/cli_dispatch_test.exs`
  - `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`
  - `apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs`
- Open bugs / gaps (todo entry "Codex PR #356 r1 HIGH/MED deferred"):
  - **HIGH-1**: CLI integration tests for User-Kind actions (`mint_token`, `set_password`, `grant_cap`) do not exist yet. Most existing tests cover Session-Kind, not User-Kind. Adding a parallel User-Kind suite is the next gap.
  - **HIGH-2**: `UserTokens` Behavior carries `mint/list/revoke` — same cap subject for all three. Action-axis (PR #410) made the cap struct narrower, but the cap-narrow grant path is admin-only (todo entry "Entity-caps LV grant form needs action-selector dropdown").
  - **HIGH-4**: LV-side `EzagentPluginLiveview.UsersLive` still calls `Ezagent.Users.create/3` directly (bypasses dispatch). Migration to dispatch path is pending.

## Notes

- Token-revoke + in-flight CLI session: current behavior is "next call denied", but an in-progress streaming dispatch is not interrupted. Consider whether this needs to change pre-prod GA.
- `feedback_test_commands_before_suggesting`: any CLI examples here should be runnable from `esr exec ezagent identity list_api_keys ...` shape before being shipped to operators.
