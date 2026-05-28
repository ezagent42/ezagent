# Scenario 04: Cross-workspace agent token use (codex external agent)

**Category**: 1 — Auth / Identity
**Status**: ❌ not-implemented
**Last verified**: never (scenario does not yet exist as runnable)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin has minted a token for an end-user U in workspace W1 (scenario 03)
- A codex agent or external CLI agent A operates in workspace W2 and needs to dispatch into W1 on behalf of U

## Actors

- **Caller**: codex external agent in W2 holding U's W1 token
- **Target**: any URI in W1 (e.g. `session://<...>/W1/<...>`)
- **Behavior**: `Ezagent.Behavior.UserTokens` (auth) + the dispatched Behavior on the target

## Steps (intended — not yet wired)

1. Admin in W1 mints token T for user U; T carries `workspace_uri: workspace://W1`.
2. Codex agent A in W2 reads T (delivered via secure channel — TBD; today there is no enrollment protocol).
3. A dispatches `chat.send` against `session://W1/<id>` with `EZAGENT_TOKEN=T`.
4. The dispatch passes:
   - `authz_check`: T's `workspace_uri` matches target's workspace.
   - `cross_workspace_check` (Invocation §5.6): the caller's *operating* workspace is W2, but T's `workspace_uri` is W1, so the request is in-bounds.
5. The target session receives the message; A's reply flows back.

## Expected outcomes

- The token's subject (U) is recorded as `ctx.caller`, NOT the codex agent.
- An audit row indicates "delegated dispatch: A acted as U".
- Cross-workspace cap leak is prevented: A cannot perform an action U lacks the cap for.

## Failure modes to test

- A holds T but tries an action U lacks the cap for: `:unauthorized` per the action-axis check.
- T is revoked (scenario 03 step 10) while A is mid-stream: the next dispatch fails; in-flight is not interrupted (gap, see scenario 03 Notes).
- A in W2 holds a token for U scoped to W3: dispatch into W1 fails `:cross_workspace_denied`.

## Cross-references

- Related PRs: none — this scenario is anticipated but not yet wired.
- Related SPECs:
  - `2026-05-20-username-and-auth-design.md` — mentions delegated tokens conceptually
  - `2026-05-27-agent-bridge-domain-extraction.md` — codex bridge plumbing (auth pre-conditions but not the token-handoff path)
- Tests: none
- Open bugs / gaps:
  - **No enrollment protocol**: how A obtains T is unspecified. Options: (a) admin manually places T in A's config_dir; (b) U authorizes A via OAuth-like flow.
  - **No delegated-dispatch audit shape**: today `invocations` records `ctx.caller` only; there is no "acting-as" record. Would need a new column or `metadata` field.
  - **No cross-workspace cap check for token subjects**: today `cross_workspace_check` looks at the dispatcher's process workspace, not the token's subject workspace. Needs SPEC.

## Notes

- This scenario is the **prerequisite for codex v2** (Allen 2026-05-27 — `agent-bridge-pr-g`). Without it, codex agents can only operate in the workspace their bridge is registered to.
- This is the headline gap in Category 1; absence is honestly flagged in master README §6 "secondary investments".
