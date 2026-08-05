# Task 4 Report — Winner child-init ownership transaction

## Status

Implemented the Agent-domain `LaunchCoordinator` and wired
`Ezagent.Entity.Agent.before_start/1` to consume trusted launch context before
Kind visibility, readiness, or snapshot initialization.

## RED → GREEN evidence

- RED command:
  `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs`
- RED result: 5 failures, all `UndefinedFunctionError` for the absent
  `LaunchCoordinator.consume_before_start/2`; the inherited spawn tests passed.
- GREEN result for the same command: 12 tests, 0 failures.
- Required invariant:
  `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/kind_provenance_test.exs`
  — 1 test, 0 failures.

## Behavior proved

- Exact canonical Agent type, requested URI, structural workspace, same-workspace
  root, and non-empty attempt are validated before writes.
- Creation inventory and direct lineage use their frozen exact-write APIs in one
  `Repo.transaction`; either conflict rolls back the other fact.
- ETS lineage publication, WorkspaceRegistry binding, and authority
  acknowledgement occur only after durable commit and cannot reverse ownership.
- Exact replay converges even when authority acknowledgement fails; conflicting
  replay fails closed.
- A deterministic acknowledgement barrier proves durable facts exist while
  KindRegistry, ReadyGate, and KindSnapshot remain absent. Killing the spawning
  caller at that barrier does not remove inventory or lineage.
- Transaction failures publish no lineage cache, workspace binding, or
  acknowledgement, and the Agent hook is a no-op for legacy starts without
  launch context.
- No ownership branch was added to Core.

## Scope

The unrelated untracked handoff
`docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md`
was preserved and excluded.

## Review correction after `a5e1db592`

- Added a compile-time-selected Agent-domain persistence seam. Its test
  implementation provides a deterministic pre-transaction/pre-commit barrier
  and separately injected inventory and lineage failures; production retains
  the single `Repo.transaction` exact-write path.
- The barrier and both failures now run through `Ezagent.Kind.spawn/3` and
  `Ezagent.Entity.Agent.before_start/1`. Tests assert the spawn result plus
  absence of KindRegistry, ReadyGate, KindSnapshot, the opposite durable fact,
  lineage cache, and WorkspaceRegistry as applicable.
- Added a narrow post-commit publisher behaviour. Production publishes lineage
  cache, binds WorkspaceRegistry, then acknowledges the authority in that exact
  order. A compile-time test implementation raises specifically at lineage
  cache publication; the test proves exact durable inventory/lineage survive
  and an identical replay receipt succeeds.
- Added an independent authority resolution case returning a different facts
  `agent_uri`; coordinator validation returns `:agent_uri_mismatch` with no
  writes or publications.

Fresh correction verification after formatting:

- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs`
  — Agent suite 11 tests, 0 failures; Session suite 6 tests, 0 failures.
- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/kind_provenance_test.exs`
  — 1 test, 0 failures.

## Second review correction after `5e242ad5e`

- Removed the configurable `LaunchPersistence` behaviour, production adapter,
  and test configuration. `LaunchCoordinator` again visibly and directly calls
  the fixed `CreationInventory.record_exact/5` and
  `AgentLineage.record_exact/3` APIs inside its transaction.
- Retained only a compile-time test-build hook around the fixed calls. The
  production build compiles the hook as a direct no-op and exposes no runtime
  or configuration-selected ownership persistence extension point.
- Moved the deterministic barrier inside `Repo.transaction`, after both exact
  writes return and immediately before the transaction callback returns. The
  real `Kind.spawn/3` test uses a separate PostgreSQL connection to prove
  KindSnapshot, inventory, and lineage are externally invisible while the
  transaction is blocked, while KindRegistry and ReadyGate are also absent.
  Releasing the barrier commits the facts before the child becomes visible.
- Inventory failure remains injected before its fixed call; lineage failure is
  injected after inventory and before its fixed call, proving rollback through
  real Agent initialization.

Fresh second-correction verification after formatting:

- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs`
  — Agent suite 11 tests, 0 failures; Session suite 6 tests, 0 failures.
- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/kind_provenance_test.exs`
  — 1 test, 0 failures.

---

## Task 4 — World credential-admission surface

### Implemented

- Added `session.agent_admission.begin`, `.complete`, and `.cancel` to the
  conversation dispatch allowlist. The handlers accept only the current session,
  role name, and attempt id; flavor, source, and candidate identity remain
  server-owned.
- Projected sanitized admission rows into initial conversation state,
  `world:state`, and `members:update`. The browser receives role, flavor,
  status, attempt id, optional provisional agent URI, descriptor, and failure
  code—never a credential source URI, config path, token, or raw status.
- A PTY admission uses only the provisional URI returned by `AgentAdmission`.
  It confirms the current durable role/attempt/URI relationship before entering
  the existing `switch_to_pty/3` path, which retains `Pty.Access.may_read?/3`.
- Added a message-list card for pending, in-progress, failed, and API-key
  admissions. It derives text from the normalized descriptor rather than flavor
  checks. API-key candidates reuse the existing secure agent-key form; after a
  key is saved, World completes the matching server-owned admission and refreshes
  the conversation.

### RED → GREEN evidence

- RED backend: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs`
  initially failed because all three admission actions were absent from the
  conversation allowlist.
- RED frontend: `mise exec node@22.23.1 -- pnpm --dir apps/ezagent_plugin_world/assets test -- Conversation.test.tsx`
  initially failed because no pending/API-key/retry card was rendered.
- GREEN backend: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs`
  — 21 tests, 0 failures (the existing PTY fixture emits one known deferred
  dispatch error log while its assertions pass).
- GREEN frontend: `mise exec node@22.23.1 -- pnpm --dir apps/ezagent_plugin_world/assets lint`,
  `... typecheck`, and `... test -- Conversation.test.tsx` — 43 tests, 0 failures.
- `mise exec -- mix format --check-formatted` and `git diff --check` passed.

### Shared blocker

`mise exec -- mix compile --warnings-as-errors` is currently blocked before
Task 4 compilation by two pre-existing `ezagent_actor` type warnings:
`apps/ezagent_actor/lib/ezagent/snapshot_store.ex:283` and
`apps/ezagent_actor/lib/ezagent/kind/snapshot.ex:540`. Both concern an
unreachable `{:error, _}` clause after `forced_snapshot_failure/1`; no Task 4
file is named by the compiler and this task leaves those files unchanged.

### Review follow-up — API-key admission binding

- API-key saves now inspect the current session's durable admission before the
  identity write. A matching candidate must have a binary role/attempt, exact
  provisional URI, an active `:authenticating` or `:materializing` state, and
  a `{:api_key, %{provider: ...}}` descriptor matching the submitted provider.
  Wrong-provider, inactive, and stale/mismatched candidate rows are rejected
  before a key is stored or an admission completion can run.
- The reused secure `AgentApiKeys` form accepts an optional declared provider;
  the card supplies it as a prefilled, read-only value. Ordinary agent-key
  pages remain editable.
- The card heading and connection/retry/complete labels now include the
  descriptor label; role name is contextual text only.
- RED: the new backend matcher test failed with missing
  `WorldLive.api_key_admission_matches?/4`; the frontend test failed because
  the form did not prefill or lock the provider. GREEN: focused World backend
  tests 22/0; lint/typecheck; Conversation tests 43/0; formatter and diff
  checks passed.

### Final review follow-up — public PTY and automatic API-key completion

- `session.pty.open` now first requires the requested session to be the active
  World session, then permits its target only when it is a current session
  member or the same session's active (`:authenticating`/`:materializing`)
  admission candidate. The existing `Pty.Access.may_read?/3` gate remains in
  force before this relationship check.
- The API-key card no longer renders a manual completion action. The only
  completion path is the server-side verified save flow; cancel/retry remain.
- RED: a live Agent with a valid manage cap could still be opened through an
  unrelated `session.pty.open`; the API-key card still rendered the manual
  completion label. GREEN: World focused backend tests 22/0 and Conversation
  tests 43/0; frontend lint passed; formatter and diff checks passed.
- Frontend typecheck is currently blocked by the separately assigned
  `assets/e2e/world.spec.ts`: its test bridge calls `emit`/`contract`, but the
  declared bridge type lacks both members (five TS2339 errors). Task 4 did not
  modify that file or its E2E harness.

---

# Task 4 report — race-safe multi-session reuse

## Delivered

- Reuse joins now revalidate the installing operator's durable manage authority immediately before `Participants.add_participant/3`.
- A revocation in the preflight-to-join window returns `{:reuse_agent_revalidation_failed, role_name, :unauthorized}`, which the installer records as the durable `:unavailable` unfilled slot instead of attempting fresh materialization.
- Added coverage for the revocation path, including assertions that the reused agent stays alive and no fresh-spawn receipt is emitted.
- Added reuse-lifetime coverage: one external agent can join sessions A and B; removing it from A, or destroying A, preserves its B membership and process.

## Verification

- Focused regression command (with the prescribed PostgreSQL test environment) passed: `5 tests, 0 failures (32 excluded)`.
- A full two-file target run and `mix precommit` were started. Both remained actively CPU-bound and then exited, but their detached runners did not return final stdout/exit summaries through the tool interface.
- The test environment emits pre-existing startup warnings about divergent built-in socialware definitions and fire-and-forget default-session dispatch denials; they did not fail the focused coverage.

## Scope

Only the reuse revalidation, its two authorized integration-test files, and this appended Task 4 report entry are part of this task. Existing Task 1 and Task 2 report changes remain untouched.

## Review follow-up — complete reuse contract

- Revalidation immediately before the reuse join now checks all three durable
  contract axes together: recipe provenance, stored agent flavor, and the
  installing operator's current Manage authority.
- Each failed axis returns the non-fatal
  `{:reuse_agent_revalidation_failed, role_name, reason}` skip, so the normal
  installer records an `:unavailable` unfilled role and never substitutes a
  fresh agent.
- Reuse fixtures now persist their expected flavor. The revoke regression calls
  the real composition-install preflight before revocation, then performs the
  actual install; new recipe- and flavor-drift regressions prove the same
  durable-unfilled behavior.

### RED → GREEN evidence

- RED: before this follow-up, the flavor-drift regression returned
  `{:ok, %{satisfied: [role_name], skipped: []}}`, proving that the existing
  agent joined despite a stored flavor different from the declaration.
- GREEN:

  ```sh
  MIX_ENV=test POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 \
  POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres \
  mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1635 \
    apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1663 \
    apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1732 \
    apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1826 \
    apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1861 \
    apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1895 \
    --seed 0 --max-cases 1
  ```

  completed with `6 tests, 0 failures (28 excluded)`.
