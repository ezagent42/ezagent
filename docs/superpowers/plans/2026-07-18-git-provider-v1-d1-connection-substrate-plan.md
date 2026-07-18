# Git Provider V1 D1 Connection Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a provider-neutral, durable provider-connection domain with exact CapBAC commands, single-use authorization callbacks, fenced refresh/revoke recovery, and replaceable D0 backends without changing Git operations or Plan C.

**Architecture:** A new `ezagent_domain_provider_connection` app depends only on `ezagent_core`. Ecto aggregates are the durable source of truth; an addressable `ProviderConnection` Resource using `Ezagent.Lifecycle` is the only mutation entry. Provider plugins implement a connection driver while the existing `GitTaskAccess -> DomainGit.Adapter` path remains the only Git-operation authority.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto/PostgreSQL through `Ezagent.Repo`, `Ezagent.Lifecycle`, `Ezagent.Router`/`Invocation`, CapBAC ISSUE→STORE→VERIFY, ExUnit, supervised registries, deterministic clocks and test barriers.

## Global Constraints

- Work only in `/home/huangjiajia/ezagent/.worktrees/git-domain-spine` on `feat/git-domain-spine`.
- Read `AGENTS.md`, the approved D1 design, Plan A/B/C/D0 specs/returns, `ezagent-developer`, `elixir-phoenix-helper`, CapBAC, and Lifecycle references before code.
- Use strict RED/GREEN TDD; every task runs its focused test before its commit.
- Use `use Ezagent.Lifecycle`; developer/domain code must not write `use Ezagent.ActionSet`, `invoke/4`, `init_slice`, or `state_slice`.
- Dispatch is the only inter-Kind path. Capability checks occur at the runtime chokepoint through exact `required_caps/0` declarations.
- `Ezagent.ActionSet.GitTaskAccess` remains the only Git-operation authorization entry. Do not modify `Ezagent.DomainGit.Adapter`, `OperationContext`, task policy, Plan C workspaces, Agent launch context, Kanban, or World.
- D1 implements the local authorization backend only. Production encrypted credential storage, key rotation, and production operation leases remain D2.
- Provider credentials never enter structs with public inspection, Agent state/home, config directories, task worktrees, prompts, transcripts, snapshots, events, audit payloads, telemetry, errors, or Kanban.
- Preserve the untracked `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md` and `docs/together/2026-07-18/`; never stage, delete, or edit them.
- Use migration `20260718000000_create_provider_connections.exs`; do not rewrite integrated migrations.
- All tenant tables carry `workspace_uri TEXT NOT NULL` plus an index and every query scopes by workspace.
- No raw RPC/eval/live-DB mutation, PAT-first flow, SSH, private checkout, provider HTTP, UI, deployment, merge, or push without separate authorization.

---

## File map

Create one focused module per responsibility:

```text
apps/ezagent_domain_provider_connection/
├── mix.exs
├── lib/ezagent_domain_provider_connection/application.ex
├── lib/ezagent/provider_connection/
│   ├── connection.ex                 # durable connection schema + closed changesets
│   ├── authorization_attempt.ex      # state/PKCE correlation record
│   ├── operation.ex                  # replace/refresh/revoke recovery ledger
│   ├── event.ex                      # secret-safe append-only audit event
│   ├── types.ex                      # closed ids/status/errors/scopes
│   ├── store.ex                      # row locks, CAS, transitions, scoped reads
│   ├── transition.ex                 # pure legal-transition table
│   ├── driver.ex                     # provider plugin connection-flow behaviour
│   ├── driver_registry.ex            # {provider_id, method} -> driver
│   ├── provider_authorization_backend.ex
│   ├── credential_backend.ex
│   ├── backend_registry.ex           # selected replaceable backend modules
│   ├── local_authorization_backend.ex
│   ├── callback_consumer.ex
│   ├── credential_replacement.ex
│   ├── refresh.ex
│   ├── termination.ex                # revoke/disconnect obligations
│   ├── recovery.ex                   # bounded boot recovery
│   ├── selector.ex                   # exact active-connection lookup for D2
│   └── boot_registration.ex
├── lib/ezagent/entity/provider_connection.ex
└── lib/ezagent/behavior/provider_connection.ex
```

Schemas live in the new domain app but use the shared `Ezagent.Repo`. The only
migration lives in `apps/ezagent_core/priv/repo_pg/migrations/` because that is
the umbrella's existing migration source of truth.

---

### Task 1: App boundary, closed values, and dependency gate

**Files:**
- Create: `apps/ezagent_domain_provider_connection/mix.exs`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent_domain_provider_connection/application.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/types.ex`
- Create: `apps/ezagent_domain_provider_connection/test/test_helper.exs`
- Create: `apps/ezagent_domain_provider_connection/test/architecture/dependency_boundary_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/types_test.exs`

**Interfaces:**
- Consumes: `Ezagent.URI`, `Ezagent.Repo`, and core CapBAC/Lifecycle contracts only.
- Produces: `Ezagent.ProviderConnection.Types` with closed statuses, operation classes, errors, subject/scope validation, and safe correlation ids.

- [ ] **Step 1: Write the failing boundary and type tests**

```elixir
defmodule Ezagent.ProviderConnection.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  test "the connection domain depends only on core" do
    mix = File.read!(Path.expand("../../../mix.exs", __DIR__))
    assert mix =~ ~s({:ezagent_core, in_umbrella: true})
    refute mix =~ "ezagent_domain_git"
    refute mix =~ "ezagent_domain_workspace"
    refute mix =~ "ezagent_domain_identity"
    refute mix =~ "ezagent_plugin_"
  end
end
```

```elixir
test "statuses and errors are closed" do
  assert Types.connection_statuses() == [
           :pending_authorization, :active, :refresh_required, :refreshing,
           :degraded, :expired, :revoking, :revoked,
           :disconnecting, :disconnected
         ]

  assert :callback_already_consumed in Types.errors()
  assert :callback_in_progress in Types.errors()
  assert :refresh_lease_lost in Types.errors()
  refute Enum.any?(Types.errors(), &is_map/1)
end
```

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/architecture/dependency_boundary_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/types_test.exs`

Expected: FAIL because the app and `Types` do not exist.

- [ ] **Step 3: Add the minimal app and closed types**

```elixir
defmodule EzagentDomainProviderConnection.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_provider_connection,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [{:ezagent_core, in_umbrella: true}]
    ]
  end

  def application,
    do: [extra_applications: [:logger], mod: {EzagentDomainProviderConnection.Application, []}]
end
```

Implement `Types` with literal closed lists, exact URI/workspace validation, normalized lowercase provider ids, governed-host validation that rejects URL userinfo/path/query, and non-echoing errors. Do not call `String.to_atom/1`.

- [ ] **Step 4: Run GREEN and format**

Run: `mix format apps/ezagent_domain_provider_connection`

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/architecture/dependency_boundary_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/types_test.exs`

Expected: both files pass with 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): add domain boundary"
```

### Task 2: Tenant schemas, migration, uniqueness, and legal transitions

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260718000000_create_provider_connections.exs`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/connection.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/authorization_attempt.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/operation.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/event.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/transition.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/schema_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/transition_test.exs`
- Test: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`

**Interfaces:**
- Consumes: Task 1 closed statuses and validation.
- Produces: four Ecto schemas and `Transition.allowed?/2 :: boolean()`.

- [ ] **Step 1: Write RED schema/constraint tests**

Assert exact schema fields, `workspace_uri` required in all changesets, immutable fields excluded from update changesets, and migration source contains:

```elixir
create unique_index(:provider_connections, [:connection_uri])
create unique_index(:provider_connections, [
  :workspace_uri, :owner_uri, :provider_id, :governed_host,
  :external_account_id, :execution_identity
], where: "status NOT IN ('revoked', 'disconnected')",
   name: :provider_connections_active_identity_unique)
```

Add check constraints for closed statuses, non-negative versions, positive attempt generation, and `lease_until` only on leased operations. Add indexes for `(workspace_uri, owner_uri)`, authorization ref, `(status, expires_at)`, and `(status, lease_until)` recovery scans.

- [ ] **Step 2: Write RED transition tests**

```elixir
test "only the closed transition graph is legal" do
  assert Transition.allowed?(:pending_authorization, :active)
  assert Transition.allowed?(:active, :refresh_required)
  assert Transition.allowed?(:refreshing, :active)
  assert Transition.allowed?(:active, :revoking)
  assert Transition.allowed?(:revoking, :revoked)
  refute Transition.allowed?(:revoked, :active)
  refute Transition.allowed?(:disconnected, :pending_authorization)
end
```

- [ ] **Step 3: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/schema_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/transition_test.exs`

Expected: FAIL on missing schemas/migration/transition module.

- [ ] **Step 4: Implement migration, schemas, and pure transition table**

Use `:utc_datetime_usec`; use `field :provider_metadata, :map` only for normalized non-secret metadata and validate an allowlisted scalar/string-list shape. Never cast owner/workspace/backend refs from user params; trusted constructors set them explicitly.

```elixir
@allowed %{
  pending_authorization: [:active],
  active: [:refresh_required, :degraded, :expired, :revoking, :disconnecting],
  refresh_required: [:refreshing, :degraded, :expired, :revoking, :disconnecting],
  refreshing: [:active, :degraded, :expired, :revoking, :disconnecting],
  degraded: [:refresh_required, :expired, :revoking, :disconnecting],
  expired: [:revoking, :disconnecting],
  revoking: [:revoked, :degraded],
  revoked: [],
  disconnecting: [:disconnected, :degraded],
  disconnected: []
}
```

- [ ] **Step 5: Migrate and run GREEN**

Run: `mix ecto.migrate`

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/schema_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/transition_test.exs apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`

Expected: 0 failures and the tenant invariant recognizes all four new tables.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_core/priv/repo_pg/migrations/20260718000000_create_provider_connections.exs apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): persist connection lifecycle"
```

### Task 3: Driver/backend ports and atomic boot registration

**Files:**
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/driver.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/driver_registry.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/provider_authorization_backend.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/credential_backend.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/backend_registry.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/boot_registration.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent_domain_provider_connection/application.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/contract_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/application_boot_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/architecture/registry_boundary_test.exs`

**Interfaces:**
- Produces: frozen D0 backend callbacks; `Driver.begin/1`, `consume/1`, `refresh/1`, `revoke/1`; registry lookup restricted to connection-domain orchestration modules.

- [ ] **Step 1: Write RED callback inventory tests**

```elixir
assert Enum.sort(ProviderAuthorizationBackend.behaviour_info(:callbacks)) ==
         Enum.sort(begin_authorization: 1, consume_callback: 1,
                   reauthenticate: 1, cancel_authorization: 1)

assert Enum.sort(CredentialBackend.behaviour_info(:callbacks)) ==
         Enum.sort(store: 1, replace: 1, status: 1,
                   lease_for_operation: 1, consume_lease: 1, revoke: 1)
```

Assert no callback name contains `decrypt`, `plaintext`, `fetch_secret`, `export`, `token`, or `with_secret`.

- [ ] **Step 2: Write RED boot rollback/restart tests**

Inject failure on the Nth capability/driver/backend registration, assert every registration owned by that boot attempt is removed, pre-existing identical registrations survive, conflicts fail loud, and registry restart deterministically reconciles desired declarations without calling driver/backend callbacks.

- [ ] **Step 3: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/contract_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/application_boot_test.exs apps/ezagent_domain_provider_connection/test/architecture/registry_boundary_test.exs`

Expected: FAIL on missing behaviours and registries.

- [ ] **Step 4: Implement behaviours and supervised registries**

Use one driver key constructor:

```elixir
@spec key(String.t(), String.t()) :: {:ok, {String.t(), String.t()}} | {:error, atom()}
def key(provider_id, method) do
  with {:ok, provider_id} <- Types.provider_id(provider_id),
       {:ok, method} <- Types.acquisition_method(method),
       do: {:ok, {provider_id, method}}
end
```

`BackendRegistry` stores exactly one authorization module and one credential module from application configuration; it is dependency injection, not authority. Application child order is registries → boot registration → recovery.

- [ ] **Step 5: Run GREEN and structural scan**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/contract_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/application_boot_test.exs apps/ezagent_domain_provider_connection/test/architecture/registry_boundary_test.exs`

Run: `mix ezagent.arch.scan`

Expected: focused tests pass; architecture counters do not regress.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): register drivers and backends"
```

### Task 4: Store, Resource/Lifecycle facade, and exact CapBAC

**Files:**
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/store.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/entity/provider_connection.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/behavior/provider_connection.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/boot_registration.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/store_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/action_set/provider_connection_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/integration/provider_connection_dispatch_test.exs`

**Interfaces:**
- Produces: `Store.fetch_active/1`, `Store.transition/4`, Resource URI constructor, seven exact Lifecycle actions.

- [ ] **Step 1: Write RED Store tests**

Cover exact workspace scoping, row locking, expected-version CAS, immutable binding conflicts, terminal-state rejection, and no update when `Transition.allowed?/2` is false.

```elixir
assert {:error, :stale_connection_version} =
         Store.transition(scope, connection.id, old_version, :refreshing)
```

- [ ] **Step 2: Write RED CapBAC/dispatch tests**

Use real signed ISSUE→STORE→VERIFY artifacts and exact
`resource://<workspace>/provider-connection/<id>` instances. Cover right cap,
wrong grantee, workspace, instance, action, unsigned artifact, and no cap. Every
denied case must assert unchanged DB rows plus zero driver/backend probe calls.

- [ ] **Step 3: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/store_test.exs apps/ezagent_domain_provider_connection/test/ezagent/action_set/provider_connection_test.exs apps/ezagent_domain_provider_connection/test/integration/provider_connection_dispatch_test.exs`

Expected: FAIL on missing Store/Resource/Lifecycle.

- [ ] **Step 4: Implement Store and Lifecycle**

```elixir
@actions [:begin_authorization, :consume_callback, :reauthorize,
          :refresh, :revoke, :disconnect, :read_connection]

@impl Ezagent.ActionSet
def required_caps do
  Map.new(@actions, &{&1, Ezagent.Capability.cap(:resource, __MODULE__, &1)})
end
```

Use `create/1` only for validated non-secret identity/version cache. Each handler reloads the Ecto aggregate and delegates to a focused orchestrator. Do not cap-check in handlers. Do not put backend refs or provider metadata in Lifecycle state.

- [ ] **Step 5: Run GREEN and CapBAC invariants**

Run the focused command from Step 3.

Run: `mix ezagent.check_invariants`

Run: `mix ezagent.check_invariants.lifecycle`

Expected: focused tests and both invariant tasks pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): add authorized lifecycle"
```

### Task 5: Single-use authorization and local authorization backend

**Files:**
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/callback_consumer.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/callback_consumer_test.exs`
- Test support: `apps/ezagent_domain_provider_connection/test/support/fake_driver_a.ex`
- Test support: `apps/ezagent_domain_provider_connection/test/support/fake_driver_b.ex`
- Test support: `apps/ezagent_domain_provider_connection/test/support/deterministic_clock.ex`
- Test support: `apps/ezagent_domain_provider_connection/test/support/barrier.ex`

**Interfaces:**
- Produces: local D0 authorization backend and `CallbackConsumer.consume/3`.

- [ ] **Step 1: Write RED authorization tests**

Cover subject binding to owner/workspace/provider/host/connection/version/method,
registered redirect id, permission digest, expiry, state mismatch, PKCE mismatch,
cancel, reauthentication expiry, and rejection of product/social-login material.

- [ ] **Step 2: Write RED concurrent callback tests**

Use a barrier after `pending -> consuming`. Race two Tasks with the same ref;
assert exactly one backend credential handoff, one `consumed` attempt, one active
binding, and loser errors `:callback_in_progress` or
`:callback_already_consumed`. Replay after restart must remain consumed.

- [ ] **Step 3: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/callback_consumer_test.exs`

Expected: FAIL on missing implementation.

- [ ] **Step 4: Implement exact attempt claiming**

Inside an Ecto transaction, lock the attempt, validate subject/version/expiry,
and change only `pending -> consuming`. Perform the external/backend call after
the transaction; finish through expected-attempt-version CAS. Persist only
digests/opaque refs. Never log or inspect the callback envelope.

- [ ] **Step 5: Run GREEN and restart case**

Run the command from Step 3 twice, once normally and once with the test's
supervisor restart path enabled.

Expected: all callback/replay/concurrency tests pass without sleeps.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): consume authorization once"
```

### Task 6: Credential replacement ledger and crash compensation

**Files:**
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/credential_replacement.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/credential_replacement_test.exs`
- Copy/adapt test-only frozen D0 ports/fakes into: `apps/ezagent_domain_provider_connection/test/support/d0_backend_reuse_gate/`
- Modify: `apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs`

**Interfaces:**
- Produces: `CredentialReplacement.store/2`, `replace/2`, and `recover/1` using `prepared -> backend_committed -> connection_committed -> finalized | compensation_pending -> compensated`.

- [ ] **Step 1: Write RED crash-window tests**

Use deterministic barriers at: before backend call, backend committed before DB
record, operation recorded before connection CAS, connection committed before
old revoke, stale CAS, compensation before/after response loss. Assert the
existing active credential remains usable until pointer CAS, winner versions
never roll back, and stale produced credentials are revoked.

- [ ] **Step 2: Write RED local/remote-shaped conformance tests**

Run the same cases against the in-process fake and serialized remote-shaped
fake. Assert swapping modules changes configuration only. Assert ambiguity is
reconciled by correlation id/version, not process identity.

- [ ] **Step 3: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/credential_replacement_test.exs apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs`

Expected: FAIL on missing replacement protocol and new ownership gate.

- [ ] **Step 4: Implement minimal replacement/recovery protocol**

Never call a backend from inside a DB transaction. Persist the deterministic
operation before the effect, then reconcile the effect with the same
correlation id. `recover/1` is idempotent for every operation state and refuses
unknown or out-of-scope opaque refs.

- [ ] **Step 5: Run GREEN and secret serialization checks**

Run the command from Step 3.

Expected: both backend shapes pass; captured serialized payloads contain no
sentinel token/refresh material/sensitive wrapper.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_provider_connection apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs
git commit -m "feat(provider-connection): recover credential replacement"
```

### Task 7: Refresh lease, revoke/disconnect, and boot recovery

**Files:**
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/refresh.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/termination.ex`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/recovery.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent_domain_provider_connection/application.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/refresh_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/termination_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/recovery_test.exs`

**Interfaces:**
- Produces: fenced refresh claims, idempotent provider/backend termination obligations, and bounded boot recovery.

- [ ] **Step 1: Write RED refresh race tests**

Race two attempts using deterministic time. Assert exactly one lease winner;
`now == lease_until` loses authority; takeover succeeds; a stale successful
provider result is compensated and cannot update connection/credential
versions.

- [ ] **Step 2: Write RED revoke/disconnect tests**

Assert `active/degraded/expired -> revoking|disconnecting` blocks new leases
before calling the driver. Inject driver failure, backend failure, response loss,
and restart. Terminal status is written only after both obligations confirm.

- [ ] **Step 3: Write RED bounded recovery tests**

Seed each non-terminal operation state, restart the application supervisor, and
assert recovery resumes only expired/owned work. Active leases remain untouched;
stale snapshots cannot complete a replacement claim.

- [ ] **Step 4: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/refresh_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/termination_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/recovery_test.exs`

Expected: FAIL on missing orchestration modules.

- [ ] **Step 5: Implement refresh, termination, and one-shot recovery**

Use DB claim tokens and exact expected versions. Recovery uses ordered bounded
queries: compensation/termination obligations first, then expired refreshes,
then incomplete callback/replacement records. It never scans/deletes opaque
backend data or retries active leases.

- [ ] **Step 6: Run GREEN**

Run the command from Step 4.

Expected: all deterministic concurrency/restart cases pass with 0 failures.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): fence refresh and termination"
```

### Task 8: Exact active selector and D2 operation boundary proof

**Files:**
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/selector.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/selector_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/architecture/git_authority_boundary_test.exs`
- Modify: `apps/ezagent_domain_git/test/architecture/adapter_registry_boundary_test.exs`

**Interfaces:**
- Produces: `Selector.active_connection/1` accepting exact authoritative owner/workspace/provider/host/execution coordinates and returning only connection id/status/version plus opaque credential ref/version.

- [ ] **Step 1: Write RED selector tests**

Assert exact selection, zero cross-owner/workspace/host/account fallback,
ambiguity failure, terminal/degraded rejection, and caller-supplied connection id
or credential ref rejected as unknown input keys.

- [ ] **Step 2: Write RED architecture tests**

Source-scan production code to prove:

- connection domain never imports/calls `Ezagent.DomainGit.Adapter` or
  `AdapterRegistry`;
- Domain Git/Plan C/Agent/Kanban contain no new connection/backend lookup;
- only a provider adapter private operation may later call
  `lease_for_operation` and unwrap a sensitive wrapper;
- no connection action authorizes repository operations.

- [ ] **Step 3: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/selector_test.exs apps/ezagent_domain_provider_connection/test/architecture/git_authority_boundary_test.exs apps/ezagent_domain_git/test/architecture/adapter_registry_boundary_test.exs`

Expected: FAIL on missing selector and boundary ledger.

- [ ] **Step 4: Implement the scoped selector and structural ledger**

```elixir
@type query :: %{
  owner_uri: URI.t(), workspace_uri: URI.t(), provider_id: String.t(),
  governed_host: String.t(), execution_identity: String.t()
}

@spec active_connection(query()) ::
        {:ok, %{connection_id: Ecto.UUID.t(), connection_version: non_neg_integer(),
                credential_ref: term(), credential_version: non_neg_integer()}}
        | {:error, :provider_account_not_connected | :connection_ambiguous}
```

The returned opaque ref is accepted only by the configured backend with the
same exact scope. Do not add this selector to invocation args or a generic RPC
surface.

- [ ] **Step 5: Run GREEN**

Run the command from Step 3.

Expected: selector and authority boundary tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_provider_connection apps/ezagent_domain_git/test/architecture/adapter_registry_boundary_test.exs
git commit -m "feat(provider-connection): select exact active connection"
```

### Task 9: Secret-safety, two-driver proof, and complete verification

**Files:**
- Test: `apps/ezagent_domain_provider_connection/test/architecture/secret_safety_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/integration/provider_neutral_connection_test.exs`
- Test: `apps/ezagent_domain_provider_connection/test/integration/restart_recovery_test.exs`
- Modify: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`
- Modify: project architecture/doc scanner ledgers only where the new legitimate modules require exact classification; do not raise a ratchet cap to hide a violation.

**Interfaces:**
- Consumes: all Tasks 1–8.
- Produces: the user-facing D1 DoD artifact and full verification ledger.

- [ ] **Step 1: Write RED secret-safety source/runtime tests**

Scan structs, schemas, Inspect output, logs, telemetry calls, events, errors,
snapshots, Agent, Plan B, Plan C, and Kanban for forbidden token/secret/wrapper/
header/provider-body fields. Inject unique sentinel credentials through success,
raise, exit, backend failure, response loss, compensation, refresh, and revoke;
assert `capture_log` and serialized events never contain the sentinel.

- [ ] **Step 2: Write RED two-driver end-to-end proof**

Register two drivers with different provider ids, acquisition methods, metadata,
refresh behavior, revoke behavior, and external account shapes. Through real
signed Resource dispatch, prove both reach active state through the same common
model, cross-driver callback refs fail, and neither common source nor persisted
row contains GitHub-specific vocabulary.

- [ ] **Step 3: Write RED restart and unauthorized-no-effect proof**

For every operation class, stop/restart the domain supervisor at each durable
barrier and prove convergence. For every wrong Cap axis, assert zero driver,
backend, DB, audit, and recovery mutation.

- [ ] **Step 4: Run the new RED suite**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/architecture/secret_safety_test.exs apps/ezagent_domain_provider_connection/test/integration/provider_neutral_connection_test.exs apps/ezagent_domain_provider_connection/test/integration/restart_recovery_test.exs`

Expected: tests fail until the last missing gates/recovery cases are wired.

- [ ] **Step 5: Make the smallest fixes and run affected suites**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test`

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test`

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test`

Expected: the full Plan C-owning Workspace suite passes with 0 failures even
though D1 must not modify Workspace production code.

Expected: all affected suites pass with 0 failures.

- [ ] **Step 6: Run every static gate independently**

```bash
mix format --check-formatted
git diff --check
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.uri_query.scan
mix ezagent.check_invariants
mix ezagent.check_invariants.lifecycle
```

Expected: every gate exits 0. If a pre-existing baseline fails, reproduce it on
the pre-D1 commit and record exact command/output; do not claim green or change
a threshold without user adjudication.

- [ ] **Step 7: Run full project gate**

Run: `SHELL=/bin/bash mix precommit`

Expected: exit 0. If it fails, use `mix test --failed` and focused files to
classify/fix all D1 failures; separately evidence any unchanged baseline.

- [ ] **Step 8: Request code review before completion**

Use `requesting-code-review` against the full D1 diff. Resolve findings through
`receiving-code-review`, rerun the focused suite and every affected static gate,
then rerun `mix precommit`.

- [ ] **Step 9: Commit verification and gate additions**

```bash
git add apps/ezagent_domain_provider_connection apps/ezagent_core/test/invariants apps/ezagent_domain_git/test/architecture
git commit -m "test(provider-connection): prove substrate invariants"
```

### Task 10: Return artifact and implementation handback

**Files:**
- Create: `docs/together/2026-07-18/returns/gaga-git-provider-plan-d1.md`
- Modify: no board/team file unless the lead explicitly requests it.

**Interfaces:**
- Produces: dev-together return with per-line DoD reconciliation, commits,
  verification output, baselines, deferrals, and method friction.

- [ ] **Step 1: Reconcile every §17 design DoD line**

For each line, record `pass`, `deferred by lead`, or `blocked`, with the exact
test path and command output. A missing proof is not silently removed.

- [ ] **Step 2: Record branch and PR facts**

```bash
git status --short --branch
git rev-parse HEAD origin/main origin/feat/git-domain-spine
git rev-list --left-right --count origin/main...HEAD
gh pr view 1445 --json url,state,isDraft,headRefName,baseRefName,mergeable,statusCheckRollup,updatedAt
```

Do not push, rebase, merge, or alter the PR unless separately authorized.

- [ ] **Step 3: Write and verify the return**

Include `returned_at`, deadline status, complete commit list, tests/gates,
unresolved baselines, explicit D2/E deferrals, no-secret assertion, and method
friction. Run `git diff --check`.

- [ ] **Step 4: Commit only the return artifact**

```bash
git add docs/together/2026-07-18/returns/gaga-git-provider-plan-d1.md
git diff --cached --check
git commit -m "docs(together): return git provider plan d1"
```

Do not stage the preserved handoffs or any unrelated `docs/together/2026-07-18`
content.

---

## Execution checkpoints

- After Task 3: review frozen contracts and boot rollback before any Lifecycle.
- After Task 5: review callback authority and single-consumption proof.
- After Task 7: adversarial review of every external-effect/DB crash window.
- After Task 9: full code review and verification-before-completion gate.
- Before Task 10: user/lead adjudicates any baseline failure or deferred DoD line.

The plan does not authorize deployment, merge, promotion, PR state changes, or
production credentials.
