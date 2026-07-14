# Task A report: durable capability delivery outbox

## Implementation

- Added the tenant-scoped `cap_delivery_outbox` PostgreSQL table and
  `Ezagent.Cap.Delivery` schema. Rows retain target, operation, serialized
  invocation/payload identity, status, attempt schedule/error, workspace, and
  timestamps.
- Routed only `identity.absorb_cap` and `identity.revoke_cap` invocations
  through `Ezagent.Cap.DeliveryOutbox`. The row is inserted before the first
  attempt; capability replays bypass the bounded ETS `PendingDelivery` queue.
  General invocations continue to use the existing ETS path unchanged.
- Added target-ready draining plus a supervised periodic sweeper. The sweeper
  rebuilds its ephemeral target-hint ETS cache from pending DB rows at boot, so
  pending work survives target-process and BEAM restarts.
- Added the internal `cap_delivery_id` replay marker and made
  `Ezagent.Kind.Server` mark a matching row applied only after the real handler
  succeeds and the slice commit returns `:ok` or `:not_durable`. Producer-side
  cast `:ok` never marks a row applied.
- Preserved existing synchronous revoke return behavior. An unavailable target
  can return its original error while the durable row remains pending. No
  synchronous waiter/request path was added.
- Added the future policy seam
  `config :ezagent_core, Ezagent.Cap.DeliveryOutbox, require_sync_ack: []`;
  the default is off and dispatch does not consume it in task A.
- Updated affected integration assertions and invariant allowlists from
  capability-specific ETS buffering to durable pending/applied rows. Existing
  `users.caps_json` and agent snapshot storage are unchanged.

## TDD evidence

### RED

The first capability-facade test was changed before implementation to require a
durable row and unchanged ETS buffer:

```text
MIX_TEST_PARTITION=entity_caps_a mix test \
  test/ezagent/identity/absorb_cap_facade_test.exs

1 test, 1 failure
Assertion with == failed
left: 1
right: 0
```

This was the old `PendingDelivery` behavior: the not-ready absorb was buffered
in ETS and there was no `cap_delivery_outbox` schema/table yet.

### GREEN during implementation

```text
# Identity facade + Grant paths, including absorb/revoke, ready drain,
# restart sweeper retry, duplicate replay idempotency, and sync-hook default
20 tests, 0 failures

# Core Invocation normal ETS/DLQ regression set
15 tests, 0 failures

# Tenant-table invariant
64 tests, 0 failures

# Cap self-store + test-isolation invariants
13 tests, 0 failures

# Core architecture / ready-transition / invocation set
37 tests, 0 failures
```

Final focused umbrella regression after migrating all affected assertions:

```text
MIX_TEST_PARTITION=entity_caps_a mix test \
  apps/ezagent_domain_agent/test/ezagent/agent/grant_recipe_caps_board_scope_test.exs \
  apps/ezagent_domain_workspace/test/integration/create_role_agent_test.exs \
  apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_domain_session/test/integration/orchestrator_scoped_cap_self_store_test.exs

ezagent_domain_agent:     5 tests, 0 failures
ezagent_domain_workspace: 24 tests, 0 failures
ezagent_domain_session:   17 tests, 0 failures
```

`git diff --check` also passed.

## Precommit result

One `MIX_TEST_PARTITION=entity_caps_a mix precommit` run was used to expose
umbrella consumers of the old capability-specific ETS assertion. Core completed
2 doctests + 2052 tests with 0 failures, and the other unaffected apps shown by
the run were green. The run was not globally green for three separate reasons:

- stale task-A ETS assertions in agent/workspace/session tests; all were
  migrated and the focused umbrella command above is green;
- existing nondeterministic setup failures in ConfigEvolve and default session
  template seeding (the ConfigEvolve assertion also reproduced on untouched
  `origin/main`, while its isolated focused run passes);
- the final web test bootstrap could not resolve
  `../node_modules/xterm/css/xterm.css` because this isolated worktree has no
  `apps/ezagent_web/assets/node_modules` install.

Per controller instruction, task A did not rerun the several-minute umbrella
gate; the controller owns the post-rebase `mix ci.local` verification.

## Files changed

- Core outbox/runtime: `apps/ezagent_core/lib/ezagent/cap/delivery.ex`,
  `delivery_outbox.ex`, `delivery_outbox/sweeper.ex`, `invocation.ex`,
  `kind/server.ex`, `kind/ready_transition.ex`, `ezagent_core/application.ex`,
  and `ezagent_core/ets_owner.ex`.
- Persistence/config:
  `apps/ezagent_core/priv/repo_pg/migrations/20260714010000_create_cap_delivery_outbox.exs`
  and `config/config.exs`.
- Contracts/tests: the two core invariant tests, Identity/Grant moduledocs and
  tests, and the affected agent/workspace/session integration tests listed in
  the final focused command.

## Concerns and handoff notes

- Delivery is intentionally asynchronous for casts. `:ok` means durable
  acceptance, not target application; synchronous ACK tiers remain future work.
- A row is applied only after handler + slice commit. If the handler commits and
  the status update is lost, replay is expected and the real absorb/revoke
  handlers provide idempotent convergence.
- A definitively failed/not-ready target leaves its capability operation pending
  for operator recovery and periodic retry; it is not converted to a
  diagnostic-only DLQ drop.
- The migration was applied to the isolated `entity_caps_a` test partition for
  local verification. Deployment still requires the normal repository
  migration gate.

## Reviewer hardening fix

The follow-up fix closes all six reviewer blockers:

- durable idempotency is now established by a nullable producer key and a
  partial unique `(workspace_uri, target_uri, op, idempotency_key)` index before
  generic ETS idempotency can consume the request;
- retries and ready-drains reconstruct a canonical version-1 invocation as
  `mode: :cast, reply: :ignore`, while the first newly inserted synchronous
  revoke still returns the original call result;
- claims are atomic conditional updates with a token and lease, and every
  applied/failure writeback is token-bound so a stale claimant cannot overwrite
  a renewed lease;
- the persisted envelope is an exact, allowlisted, safe-term-decoded version-1
  payload. Poison and permanent authorization failures are isolated as `dead`,
  while transient handler/commit failures release the claim as `pending` with
  retry metadata;
- only explicitly marked Identity absorb/revoke producers enter the durable
  path, and `Ezagent.Kind.Server` records both handler and commit failures;
- cold boot rehydrates the ETS target hint from PostgreSQL and successfully
  drains persisted work after the hint table is cleared.

### Follow-up TDD evidence

The initial hardening test run produced 9 expected failures, covering duplicate
producer retries, generic-key ordering, missing producer gating, poison-row
isolation, missing claim state, permanent failure classification, concurrent
claims, self-call ready-drain, and conflicting idempotency payloads. A separate
RED assertion showed the former persisted struct keys instead of the required
canonical envelope.

Final focused verification:

```text
# Hardening suite plus existing Identity absorb/revoke coverage
32 tests, 0 failures

# Reviewer-critical concurrency, stale-token, poison, cold-boot, and real-ready cases
4 tests, 0 failures

# Core architecture and capability invariants
181 tests, 0 failures

# Core/agent/workspace/session normal-flow regression selection
69 tests, 0 failures
```

The hardening migration was applied to the isolated `entity_caps_a` test
partition. `mix format --check-formatted` for every changed Elixir file and
`git diff --check` both passed. Per controller instruction, this follow-up did
not run the full `ci.local` gate.
