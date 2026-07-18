# Git Provider V1 D1 Connection Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the provider-neutral D1 connection substrate, including D0.1 retry reconciliation, the GitTaskAccess live-entity correction, exact owner-User CapBAC, durable authorization correlation, and fenced credential-pointer recovery.

**Architecture:** `ProviderConnection` is a five-table Ecto aggregate in a new domain app depending on `ezagent_core` and `ezagent_domain_identity`. A stateless registry-only Lifecycle behavior on the existing User Kind is the only management command boundary; provider drivers retain provider HTTP while a handoff-compatible backend pair owns authorization correlation and credential transfer. `Ezagent.ActionSet.GitTaskAccess` remains the only Git-operation authority.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL through `EzagentCore.Repo`, `Ezagent.Lifecycle`, `Ezagent.Invocation`, signed CapBAC artifacts, AEAD from Erlang `:crypto`, ExUnit, deterministic clocks/barriers, and the existing architecture scanners.

## Global Constraints

- Work only in `/home/huangjiajia/ezagent/.worktrees/git-domain-spine` on `feat/git-domain-spine`.
- Preserve and never stage, edit, or delete the untracked `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md` and `docs/together/2026-07-18/` tree.
- Read the approved D1 design, Plan A/B/C/D0 specs and returns, `AGENTS.md`, CapBAC/Lifecycle references, and the `ezagent-developer` and `elixir-phoenix-helper` skills before code.
- Use strict RED/GREEN TDD and commit only after each task's focused suite is green.
- Developer/domain behaviors use `use Ezagent.Lifecycle`; never write developer-tier `use Ezagent.ActionSet`, `invoke/4`, `init_slice/1`, or `state_slice/0`.
- All Ecto code uses `EzagentCore.Repo`; never introduce `Ezagent.Repo`.
- ProviderConnection is not a Kind and has no URI. Management dispatch targets `entity://<workspace>/user/<owner-id>`.
- The provider-connection app depends only on `ezagent_core` and `ezagent_domain_identity`; it must not depend on Domain Git, Workspace, World, Web, Kanban, or a provider plugin.
- D1 implements local authorization correlation only. Production encrypted credential storage, actual operation leases, GitHub endpoints, UI, deployment, merge, and push are deferred.
- No credential, callback code, raw state, PKCE verifier, key material, Authorization header, provider body, or sensitive wrapper may enter public structs, Inspect, logs, telemetry, events, snapshots, Agent homes, task worktrees, prompts, transcripts, or Kanban.
- Use migration `20260718000000_create_provider_connections.exs`; do not rewrite integrated migrations.
- Every tenant table has `workspace_uri TEXT NOT NULL`, an index beginning with `workspace_uri`, and workspace-scoped queries.
- Use deterministic clocks and barriers; tests must not use timing sleeps.

---

## File Map

```text
apps/ezagent_core/lib/ezagent/cap.ex                         # current-target artifact validation helper
apps/ezagent_core/priv/repo_pg/migrations/
  20260718000000_create_provider_connections.exs             # five D1 tables and constraints

apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex # live entity URI migration
apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/    # D0.1 executable contracts

apps/ezagent_domain_provider_connection/
├── mix.exs
├── lib/ezagent_domain_provider_connection/application.ex
├── lib/ezagent/provider_connection/
│   ├── types.ex                       # closed ids/status/errors
│   ├── connection.ex                  # connection schema
│   ├── authorization_attempt.ex       # public attempt schema
│   ├── authorization_backend_record.ex# private AEAD schema
│   ├── operation.ex                   # idempotency/recovery ledger
│   ├── event.ex                       # secret-safe audit row
│   ├── transition.ex                  # closed transition graph
│   ├── store.ex                       # locks/CAS/scoped queries
│   ├── driver.ex                      # provider exchange behavior
│   ├── driver_registry.ex             # driver declarations/fingerprints
│   ├── provider_authorization_backend.ex
│   ├── credential_backend.ex
│   ├── backend_pair.ex                # compatible pair declaration
│   ├── backend_pair_registry.ex
│   ├── authorization_key_ring.ex      # fail-closed AEAD config
│   ├── local_authorization_backend.ex # durable state/PKCE correlation
│   ├── callback_ingress.ex            # attempt resolve + owner dispatch
│   ├── credential_replacement.ex      # D0.1 command + pointer CAS
│   ├── refresh.ex                     # lease fencing
│   ├── termination.ex                 # revoke/disconnect obligations
│   ├── recovery.ex                    # bounded restart recovery
│   └── selector.ex                    # exact active selection for D2
└── lib/ezagent/behavior/provider_connection.ex # stateless User-Kind Lifecycle
```

### Task 1: Make D0.1 reconciliation executable

**Files:**
- Modify: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/types.ex`
- Modify: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/conformance.ex`
- Modify: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/in_process_fake.ex`
- Modify: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/remote_shaped_fake.ex`
- Modify: `apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs`

**Interfaces:**
- Consumes: the unchanged ten D0 callbacks.
- Produces: exact retry semantics keyed by `{backend_id, operation_class, correlation_id}` and canonical input digest.

- [ ] **Step 1: Add failing same-key and conflicting-key tests**

Add table-driven cases that call every mutating callback twice with identical input and assert the same logical result plus one effect. Then change one authority-bearing field while retaining the correlation id and assert `:correlation_conflict`. For callback consumption, use a new correlation id against the consumed authorization ref and assert `:callback_already_consumed`.

```elixir
test "callback reconciles exact retry and rejects correlation reuse" do
  {:ok, started} = D0.InProcessFake.begin_authorization(begin_request("begin-1"))
  request = callback_request(started, "consume-1")

  assert {:ok, first} = D0.InProcessFake.consume_callback(request)
  assert {:ok, second} = D0.InProcessFake.consume_callback(request)
  assert first == second
  assert D0.InProcessFake.provider_effect_count() == 1

  assert {:error, :correlation_conflict} =
           D0.InProcessFake.consume_callback(
             put_in(request, [:expected_subject, :connection_version], 2)
           )

  assert {:error, :callback_already_consumed} =
           D0.InProcessFake.consume_callback(%{request | correlation_id: "consume-2"})
end
```

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs --only d0_remote_shaped`

Expected: FAIL because conflicting reuse is not a closed error and exact retry behavior is not shared across all commands.

- [ ] **Step 3: Implement one command-key reconciler in the fake**

Store `%{{backend_id, operation_class, correlation_id} => %{digest: digest, result: result}}`. Compute `digest` from the canonical request with secret material replaced by a one-way digest. Exact keys/digests return `result`; key mismatch returns `{:error, :correlation_conflict}`; no branch repeats the effect counter.

```elixir
defp reconcile_command(state, backend_id, operation, correlation_id, bound_input, effect) do
  key = {backend_id, operation, correlation_id}
  digest = :crypto.hash(:sha256, :erlang.term_to_binary(bound_input, [:deterministic]))

  case Map.get(state.commands, key) do
    %{digest: ^digest, result: result} -> {:reply, result, state}
    %{digest: _other} -> {:reply, {:error, :correlation_conflict}, state}
    nil -> commit_once(state, key, digest, effect)
  end
end
```

- [ ] **Step 4: Run GREEN**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs`

Expected: all D0 contract/security tests pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git/test/support/d0_backend_reuse_gate apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
git commit -m "test(git): enforce D0 correlation reconciliation"
```

### Task 2: Migrate GitTaskAccess to a constrained live entity

**Files:**
- Modify: `apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex`
- Modify: `apps/ezagent_domain_git/lib/ezagent/domain_git/task_access_supervisor.ex`
- Modify: `apps/ezagent_domain_git/test/ezagent/entity/git_task_access_test.exs`
- Modify: `apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs`
- Modify: Plan B/C fixtures and provision-record tests found by `rg -l 'resource://.*/git-task-access|git-task-access/' apps`
- Create: `apps/ezagent_domain_git/test/architecture/git_task_access_principal_boundary_test.exs`

**Interfaces:**
- Consumes: the existing validated `%Ezagent.Entity.GitTaskAccess{}` policy.
- Produces: `uri_from_args/1 :: URI.t()` as `entity://<workspace>/worker/gta_<sha256>`; all five adapter callbacks remain unchanged.

- [ ] **Step 1: Write RED URI and principal-boundary tests**

```elixir
test "live task access has a deterministic entity worker URI" do
  {:ok, policy} = GitTaskAccess.new(policy_attrs())
  uri = GitTaskAccess.uri_from_args(policy)

  assert GitTaskAccess.__pattern__() == :entity
  assert GitTaskAccess.type_name() == :git_task_access
  assert URI.to_string(uri) =~ ~r{^entity://[^/]+/worker/gta_[a-f0-9]{64}$}
  assert uri == GitTaskAccess.uri_from_args(policy)
end
```

The architecture test scans caller/grantor/member/token/SystemPrincipal constructors and permits GitTaskAccess only as invocation target or `grantee_uri` for its own exact operations.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test/ezagent/entity/git_task_access_test.exs apps/ezagent_domain_git/test/architecture/git_task_access_principal_boundary_test.exs`

Expected: FAIL on the existing `:resource` pattern/URI and missing invariant test.

- [ ] **Step 3: Implement the canonical URI constructor**

After `revalidate/1`, serialize the complete canonical policy with deterministic term encoding, hash SHA-256, and use the lowercase hex digest as the worker id. Keep `type_name/0 == :git_task_access`, ephemeral persistence, existing supervisor, and full-policy duplicate reconciliation. Do not accept a caller-supplied id or old URI compatibility form.

```elixir
def uri_from_args(%__MODULE__{} = policy) do
  {:ok, canonical} = revalidate(policy)
  {:ok, workspace} = Ezagent.URI.workspace_name(canonical.workspace_uri)

  digest =
    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)

  Ezagent.URI.new!("entity://#{workspace}/worker/gta_#{digest}")
end
```

- [ ] **Step 4: Update all Plan B/C fixtures and run GREEN**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs`

Expected: all affected Git/workspace tests pass; `rg -n 'resource://.*/git-task-access|git-task-access/' apps` returns no live task-access URI.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git apps/ezagent_domain_workspace/test
git commit -m "fix(git): move task access to entity URI"
```

### Task 3: Add the provider-connection app, closed types, and five-table schema

**Files:**
- Create: all schema/type/transition files listed in the File Map
- Create: `apps/ezagent_domain_provider_connection/test/test_helper.exs`
- Create: `apps/ezagent_domain_provider_connection/test/architecture/dependency_boundary_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/schema_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/transition_test.exs`
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260718000000_create_provider_connections.exs`
- Modify: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`

**Interfaces:**
- Produces: five schemas, closed statuses/errors, `Transition.allowed?/2`, and DB uniqueness/check constraints.

- [ ] **Step 1: Write RED dependency, migration, constraint, and transition tests**

Assert dependencies are exactly core + identity; schema source is `EzagentCore.Repo`; all tables carry indexed `workspace_uri`; operations uniquely index `[:backend_pair_id, :operation_class, :correlation_id]`; attempts uniquely index authorization ref; backend records enforce one committed consume per authorization ref; active binding uniqueness covers workspace/owner/provider/host/account/execution identity.

```elixir
test "terminal states cannot reactivate" do
  assert Transition.allowed?(:pending_authorization, :active)
  assert Transition.allowed?(:active, :revoking)
  assert Transition.allowed?(:revoking, :revoked)
  refute Transition.allowed?(:revoked, :active)
  refute Transition.allowed?(:disconnected, :pending_authorization)
end
```

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test`

Expected: FAIL because the app, migration, schemas, and transition module do not exist.

- [ ] **Step 3: Implement the app and migration**

Use `:utc_datetime_usec`. Trusted constructors explicitly set owner/workspace/backend refs; never include them in user-param `cast/3`. Store callback artifacts as JSON-safe maps. Mark the private backend-record schema `@moduledoc false`, redact it with `@derive {Inspect, except: [:ciphertext, :nonce]}`, and expose no public fetch-by-id API.

- [ ] **Step 4: Prove constraints against PostgreSQL**

Run: `MIX_ENV=test mix ecto.migrate`

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/schema_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/transition_test.exs apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`

Expected: migration applies and actual duplicate inserts/check violations return Ecto constraint errors; no source-text-only assertion substitutes for DB execution.

- [ ] **Step 5: Verify migration reversal and commit**

Run: `MIX_ENV=test mix ecto.rollback --step 1 && MIX_ENV=test mix ecto.migrate`

Expected: both commands exit 0.

```bash
git add apps/ezagent_domain_provider_connection apps/ezagent_core/priv/repo_pg/migrations/20260718000000_create_provider_connections.exs apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs
git commit -m "feat(provider-connection): add durable aggregate"
```

### Task 4: Add framework artifact validation and exact User-Kind actions

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/cap.ex`
- Test: `apps/ezagent_core/test/ezagent/cap_test.exs`
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/behavior/provider_connection.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent_domain_provider_connection/application.ex`
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/behavior/provider_connection_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/integration/provider_connection_cap_test.exs`

**Interfaces:**
- Produces: `Ezagent.Cap.validate_for_current_target/2`; seven registry-only User actions with `:user` capability kind.

- [ ] **Step 1: Write RED helper and dispatch tests**

```elixir
test "validation checks signature and receiver without authorizing an action" do
  {:ok, artifact} = Cap.issue_for_action({:admin, admin}, owner, consume_target)

  assert :ok = dispatch_probe(owner, fn -> Cap.validate_for_current_target(artifact, owner) end)
  assert {:error, :invalid_cap_signature} =
           dispatch_probe(owner, fn -> Cap.validate_for_current_target(tamper(artifact), owner) end)
end
```

Assert all seven actions resolve on `Ezagent.Entity.User`; wrong owner/workspace/action/grantee/tampered artifact produces zero aggregate/backend/driver mutation. Assert the behavior is registry-only and never added to `User.behaviors/0` or snapshots.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/cap_test.exs apps/ezagent_domain_provider_connection/test/ezagent/behavior/provider_connection_test.exs apps/ezagent_domain_provider_connection/test/integration/provider_connection_cap_test.exs`

Expected: FAIL on the missing helper, behavior, and registrations.

- [ ] **Step 3: Implement the narrow helper and stateless Lifecycle behavior**

`validate_for_current_target/2` delegates only to the current Kind authority, validates exact receiver binding, and returns `:ok | {:error, :invalid_cap_signature | :wrong_grantee}`. It never issues, stores, dispatches, or invokes. The behavior declares exact args/returns for begin, consume, reauthorize, refresh, revoke, disconnect, and read; handlers call focused domain functions and return no `{:set, ...}` effects.

- [ ] **Step 4: Register through CapabilityRegistry and run GREEN**

Run: `SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/cap_test.exs apps/ezagent_domain_provider_connection/test/ezagent/behavior/provider_connection_test.exs apps/ezagent_domain_provider_connection/test/integration/provider_connection_cap_test.exs`

Expected: all pass; central dispatch verification remains required for every action.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/cap.ex apps/ezagent_core/test/ezagent/cap_test.exs apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): add owner command boundary"
```

### Task 5: Add driver declarations and handoff-compatible backend pairs

**Files:**
- Create: driver/backend/pair modules from the File Map
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/registry_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/support/fake_driver_alpha.ex`
- Create: `apps/ezagent_domain_provider_connection/test/support/fake_driver_beta.ex`
- Create: `apps/ezagent_domain_provider_connection/test/support/fake_backend_pairs.ex`

**Interfaces:**
- Produces: `Driver.begin/1`, `consume_callback/1`, `refresh/1`, `revoke/1`; unchanged D0 backend callbacks; pair lookup by stable pair id.

- [ ] **Step 1: Write RED behavior/registry/parity tests**

Assert exact callback lists, pair id uniqueness, immutable fingerprints, driver lookup by `{provider_id, acquisition_method}`, rejection of an untested auth/credential cross-pair, and explicit unavailable state on partial provider declaration. Two fake drivers must differ in metadata/refresh/revoke shape without common-app provider names.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/registry_test.exs`

Expected: FAIL because contracts and registries are absent.

- [ ] **Step 3: Implement supervised registries and immutable declarations**

Use ETS only as a runtime index; declaration structs are non-secret values. Registration is idempotent only for byte-identical fingerprints and fails loudly on drift. Do not claim cross-registry atomicity with Domain Git.

- [ ] **Step 4: Run GREEN and commit**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/registry_test.exs`

Expected: pass with zero failures.

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): register drivers and backend pairs"
```

### Task 6: Implement fail-closed local authorization correlation

**Files:**
- Create: `authorization_key_ring.ex`, `local_authorization_backend.ex`
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/authorization_key_ring_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`

**Interfaces:**
- Produces: durable AEAD state/PKCE records and D0.1-consistent begin/consume/cancel/reauthenticate behavior.

- [ ] **Step 1: Write RED crypto, restart, rotation, and leak tests**

Cover missing/malformed/duplicate active key boot failure; ciphertext differs across nonces; associated-data tampering fails; restart resumes an unexpired attempt; exact consume retry returns the same opaque handoff ref with one driver effect; conflicting correlation fails; finalized handoff ciphertext is shredded while its tombstone remains; old decrypt-only key removal fails while referenced; no sentinel appears in Inspect/log/error/event output.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/authorization_key_ring_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`

Expected: FAIL because key ring/backend modules are missing.

- [ ] **Step 3: Implement AEAD and the one-direction exchange**

Use `:crypto.crypto_one_time_aead/7` with AES-256-GCM, a fresh 12-byte nonce, 16-byte tag, a configured 32-byte key, and deterministic associated data from the approved bound coordinates. Store ciphertext/tag/nonce/key id only in the private record. On consume, claim the command, decrypt inside the backend, call the registered driver with a single-purpose exchange context, immediately seal returned credential material, persist only its opaque pair-private handoff ref as the logical result, and zero/drop local plaintext references. Never expose a verifier or handoff unwrap getter.

- [ ] **Step 4: Run GREEN and commit**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/authorization_key_ring_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`

Expected: all tests pass without sleeps.

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): persist authorization correlation"
```

### Task 7: Implement callback ingress, claim recovery, and credential handoff

**Files:**
- Create: `callback_ingress.ex`, `store.ex`
- Extend: `provider_connection.ex`, `authorization_attempt.ex`, `operation.ex`
- Create: `apps/ezagent_domain_provider_connection/test/integration/callback_ingress_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`

**Interfaces:**
- Produces: attempt resolution by opaque ref; owner dispatch with stored cap; `pending -> consuming -> consumed` claim protocol.

- [ ] **Step 1: Write RED end-to-end callback tests**

Test wrong/tampered artifact before attempt insert; callback parameters cannot select owner/workspace/connection/provider/host; concurrent claim has one winner; crash after backend commit resumes the same correlation/ref and has one provider effect; credential store consumes the ref only through the registered pair; pointer finalization shreds handoff ciphertext and retains a tombstone; different-correlation replay is rejected; expired/cancelled/stale-version attempts make zero backend/driver mutations.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/integration/callback_ingress_test.exs apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`

Expected: FAIL on missing ingress/claim/store functions.

- [ ] **Step 3: Implement exact attempt dispatch and bounded claims**

Ingress accepts only the opaque authorization ref plus raw provider callback envelope, loads all authority coordinates from the attempt, decodes the cap via `Capability.from_map/1`, and dispatches to the stored owner URI as that owner. Claim uses row lock, random token, attempt version, deterministic correlation, and deadline; recovery may steal only at `now >= claim_until` and must reuse the stored command.

- [ ] **Step 4: Run GREEN and commit**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/integration/callback_ingress_test.exs apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`

Expected: all pass with deterministic barriers.

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): consume callbacks once"
```

### Task 8: Implement credential pointer CAS, refresh fencing, and termination obligations

**Files:**
- Create: `credential_replacement.ex`, `refresh.ex`, `termination.ex`, `selector.ex`
- Create: `apps/ezagent_domain_provider_connection/test/integration/credential_replacement_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/integration/refresh_fence_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/integration/termination_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/selector_test.exs`

**Interfaces:**
- Produces: `prepared -> backend_committed -> connection_committed -> finalized`, exact selection, refresh lease fencing, and retryable revoke/disconnect obligations.

- [ ] **Step 1: Write RED commit-window and race tests**

Place barriers before backend call, after backend commit, before pointer CAS, after pointer CAS, and before old-ref revoke. Assert same-correlation reconciliation, stale CAS never replaces the winner, losing output becomes a cleanup obligation, old pointer remains until CAS, selection derives all coordinates and accepts no caller-provided connection id/ref, revoking/disconnecting blocks selection and records generation fence, terminal state waits for both revoke obligations.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/integration/credential_replacement_test.exs apps/ezagent_domain_provider_connection/test/integration/refresh_fence_test.exs apps/ezagent_domain_provider_connection/test/integration/termination_test.exs apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/selector_test.exs`

Expected: FAIL on missing orchestration modules.

- [ ] **Step 3: Implement transactions and fences**

Use `Repo.transaction` plus `lock: "FOR UPDATE"` for claims/CAS. Never hold a DB transaction across driver/backend calls. Persist stable correlation before the call, persist opaque result after it, then CAS exact connection and credential versions. Refresh commit requires matching unexpired lease token and both base versions. D1 selector accepts only authoritative `{owner_uri, workspace_uri, provider_id, governed_host, execution_identity}`.

- [ ] **Step 4: Run GREEN and commit**

Run the four files from Step 2.

Expected: pass with zero failures and one effect per correlation.

```bash
git add apps/ezagent_domain_provider_connection
git commit -m "feat(provider-connection): fence credential transitions"
```

### Task 9: Add bounded restart recovery and architecture/secret gates

**Files:**
- Create: `recovery.ex`
- Modify: `application.ex`
- Create: `apps/ezagent_domain_provider_connection/test/integration/recovery_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/architecture/secret_boundary_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/architecture/authority_boundary_test.exs`
- Create: `apps/ezagent_domain_provider_connection/test/architecture/provider_neutrality_test.exs`

**Interfaces:**
- Produces: bounded boot scan and invariant tests that fail on architectural regression.

- [ ] **Step 1: Write RED recovery and invariant tests**

Recovery processes batches of 50 ordered by `{inserted_at, id}`, stops after 10 batches per boot pass, and reschedules remaining work without sleep. Priority is callback/credential pointer completion, then termination cleanup, then expired refresh claims. Gates reject live `pattern: :resource`, provider names in the common app, generic secret getters, backend-owned Req/provider HTTP, GitTaskAccess principal misuse, non-User management targets, and sensitive sentinel output.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test/integration/recovery_test.exs apps/ezagent_domain_provider_connection/test/architecture`

Expected: FAIL on missing recovery worker and gates.

- [ ] **Step 3: Implement supervised bounded recovery**

Use a named GenServer under the app supervisor. `handle_continue/2` schedules an internal `:recover_batch`; each message processes at most 50 rows and queues another message only when work remains. Recovery invokes the same public orchestration functions and stored correlations as normal commands; it creates no bypass writer or new authority.

- [ ] **Step 4: Run GREEN and commit**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test apps/ezagent_domain_git/test/architecture`

Expected: all focused app and architecture tests pass.

```bash
git add apps/ezagent_domain_provider_connection apps/ezagent_domain_git/test/architecture
git commit -m "test(provider-connection): gate recovery boundaries"
```

### Task 10: Full verification, review, and handoff

**Files:**
- Modify only files required to repair failures caused by Tasks 1-9.
- Create: `docs/together/2026-07-18/returns/gaga-git-provider-plan-d1.md` only if that path is tracked/authorized at execution time; otherwise report without touching the preserved untracked handoff tree.

**Interfaces:**
- Produces: reproducible verification evidence and reviewed D1 implementation; no push/merge/deploy.

- [ ] **Step 1: Capture baseline and run focused suites**

```bash
git status --short
SHELL=/bin/bash mix test apps/ezagent_domain_git/test
SHELL=/bin/bash mix test apps/ezagent_domain_provider_connection/test
SHELL=/bin/bash mix test apps/ezagent_domain_identity/test
SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/cap_test.exs
```

Expected: zero failures attributable to D1; any pre-existing failure must be reproduced on baseline commit `8f3a53f4d` before adjudication.

- [ ] **Step 2: Run migrations, compile, and architecture gates**

```bash
MIX_ENV=test mix ecto.rollback --step 1
MIX_ENV=test mix ecto.migrate
mix compile --warnings-as-errors
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.uri_query.scan
mix ezagent.check_invariants
mix ezagent.check_invariants.lifecycle
```

Expected: every command exits 0.

- [ ] **Step 3: Run repository precommit**

Run: `mix precommit`

Expected: exit 0. Fix only D1-caused issues and rerun the focused failing command before rerunning precommit.

- [ ] **Step 4: Request code review and address findings**

Use the requesting-code-review workflow with the approved spec, this plan, base `8f3a53f4d`, and current HEAD. Review authority boundaries, secret paths, migrations, crash windows, exact test evidence, and preserved untracked files. Apply accepted findings one at a time with focused tests.

- [ ] **Step 5: Final diff and handoff commit**

```bash
git diff --check
git status --short
git log --oneline 8f3a53f4d..HEAD
```

Expected: only intended tracked D1 changes plus the two preserved untracked handoff paths. If the authorized return document was created, commit it with:

```bash
git add docs/together/2026-07-18/returns/gaga-git-provider-plan-d1.md
git commit -m "docs(together): return Git provider Plan D1"
```

If that path remains part of the preserved untracked handoff tree and was not
explicitly authorized for creation, skip this commit and report the verification
evidence directly.

Do not push, merge, deploy, rebase, or mutate PR #1445 without separate user authorization.
