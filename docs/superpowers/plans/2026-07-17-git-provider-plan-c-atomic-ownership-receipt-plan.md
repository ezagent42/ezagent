# Git Provider Plan C Atomic Ownership Receipt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Plan C task-Agent ownership recoverable across every post-create crash while ensuring an adopted Agent receives zero ownership facts from the losing attempt.

**Architecture:** Core transports a runtime-only opaque launch option and invokes a generic Kind `before_start/1` callback before registration, without importing Agent-domain concepts. Workspace owns a one-use fenced issuer; the Agent-domain coordinator resolves that authority and atomically commits the exact inventory receipt plus durable lineage in the winning child initialization.

**Tech Stack:** Elixir 1.19, OTP/DynamicSupervisor, Ecto/PostgreSQL, ExUnit, existing Ezagent Kind/Template/PreStart/CapBAC/URI primitives.

## Global Constraints

- Authoritative design: `docs/superpowers/specs/2026-07-17-git-provider-plan-c-atomic-ownership-receipt-design.md`.
- Run commands from `/home/huangjiajia/ezagent/.worktrees/git-domain-spine` with `SHELL=/bin/bash`; focused tests use `SHELL=/bin/bash MIX_ENV=test mix ...`.
- Every behavior change follows strict RED → GREEN → REFACTOR; observe the named failure before implementation and named pass before commit.
- Core owns only generic launch-option transport and the non-bypassable before-live lifecycle hook. It must not reference Agent-domain ownership modules (`Ezagent.Agent.LaunchAuthority`, `Ezagent.Agent.LaunchCoordinator`, `Ezagent.Agent.CreationInventory`), Workspace Store/Provision modules, or take a core-to-domain/plugin compile dependency.
- Core must treat `:launch_context` as an opaque runtime-only value: copy it unchanged through the sanctioned Kind spawn path, but never inspect its shape, derive fresh/adopted ownership from it, consume or acknowledge it, serialize it, log it, persist it, include it in snapshots/telemetry/crash text, or retain it across restart.
- Existing legitimate Core vocabulary and owner-gated mechanisms (`WorkspaceOwnerGate`, `LocalRuntime`, `SpawnRegistry`, plugin-facing documentation) are baseline, not violations. Structural tests must use exact forbidden module/call-site checks plus changed-line ratchets; they must not impose a whole-file zero-match ban on words such as Agent, Workspace, task, flavor, recipe, provider, or plugin.
- Plugins transport only the opaque option. They never inspect, serialize, log, cache, replace, consume it, or write inventory, lineage, WorkspaceRegistry, Provision, or retirement state.
- Opaque context never enters caller-authored Template/recipe/manifest data, URI queries, snapshots, logs, telemetry, crash text, argv/env, config directories, or provider requests.
- Preserve CapBAC retirement gates, exact `Ezagent.URI` parsing, same-workspace Agent/root validation, owner gating, and receiver-bound authority. URI membership alone never proves ownership.
- Preserve unrelated worktree state, especially `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md`; stage only task files.
- Do not push, merge, rebase, deploy, or open a pull request.
- Use Req for HTTP. Use erlexec through the repository's existing process wrappers as the sole OS-process and PTY runner; add no HTTPoison, Tesla, `:httpc`, `System.cmd`, naked `Port.open`, MuonTrap, or tmux path.
- One Elixir module per file; no core-to-domain compile dependency or plugin-to-domain ownership dependency.
- No schema change is expected. If a missing constraint is proven, revise only `apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs`; add no `05000` and do not edit `20260715001000_agent_creation_inventory.exs`.
- Existing non-Plan-C `instantiate/3`, `SpawnRegistry.register/2`, `spawn_detailed/1`, and `LocalRuntime.ensure_started_detailed/1` remain compatible. Non-empty context never falls back to a context-dropping legacy path.
- Final completion requires Task 9 full verification, audited HEAD/commit list, and passing `mix precommit`.

## Frozen interfaces

```elixir
Ezagent.Kind.spawn(module, map, keyword()) :: DynamicSupervisor.on_start_child()
Ezagent.SpawnRegistry.spawn_detailed(URI.t(), keyword()) ::
  {:ok, :started | :already_started, pid()} | {:error, term()}
Ezagent.LocalRuntime.ensure_started_detailed(URI.t(), keyword()) ::
  {:ok, :started | :already_started, pid()} | {:error, term()}

Ezagent.Agent.LaunchAuthority.register(module()) :: :ok | {:error, term()}
Ezagent.Agent.LaunchAuthority.resolve(term(), URI.t()) ::
  {:ok, %{attempt_id: String.t(), agent_uri: URI.t(), root_uri: URI.t(),
          workspace_uri: URI.t(), issuer_ref: term()}} | {:error, term()}
Ezagent.Agent.LaunchAuthority.acknowledge(term()) :: :ok | {:error, term()}

Ezagent.Agent.LaunchCoordinator.consume_before_start(term(), URI.t()) ::
  {:ok, %{attempt_id: String.t(), agent_uri: URI.t(), root_uri: URI.t(),
          workspace_uri: URI.t()}} | {:error, term()}

Ezagent.Agent.CreationInventory.record_exact(module(), String.t(), URI.t(), URI.t(), URI.t()) ::
  {:ok, :inserted | :exists} | {:error, term()}
Ezagent.Agent.CreationInventory.exact(String.t(), URI.t(), URI.t(), URI.t()) ::
  {:ok, Ezagent.Agent.CreationInventoryEntry.t()} |
  {:error, :creation_attempt_not_found | :creation_fact_conflict}
Ezagent.AgentLineage.record_exact(module(), URI.t(), URI.t()) ::
  {:ok, :inserted | :exists} | {:error, term()}
```

`Ezagent.Kind.before_start/1` is optional and returns `:ok | {:error, term()}`. `Ezagent.Entity.Agent.before_start/1` calls the coordinator only for `args[:launch_context]`. Template `instantiate/4` is optional with exact shape `instantiate(name, data, workspace_uri, launch_opts)`.

---

### Task 1: Core opaque transport and before-live hook

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind.ex`
- Modify: `apps/ezagent_core/lib/ezagent/kind/server.ex`
- Modify: `apps/ezagent_core/lib/ezagent/spawn_registry.ex`
- Modify: `apps/ezagent_core/lib/ezagent/local_runtime.ex`
- Test: `apps/ezagent_core/test/ezagent/spawn_registry_test.exs`
- Test: `apps/ezagent_core/test/ezagent/local_runtime_test.exs`
- Test: `apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs`

**Interfaces:**
- Consumes: existing two-arity Kind spawn and one-arity registered spawn functions.
- Produces: frozen option-bearing functions; registered functions may be arity one or `(uri, opts)` arity two. Arity one plus non-empty context returns `{:error, :launch_context_unsupported}`.

- [ ] **Step 1: Write failing transport and ordering tests**

Add unique-scheme tests that register an arity-two probe, pass `launch_context: make_ref()`, and assert the identical reference arrives. Register an arity-one probe and assert non-empty context fails before invocation. Add a probe Kind whose `before_start/1` blocks and can return `{:error, :probe_rejected}`; assert no snapshot, ReadyTransition registration, or KindRegistry visibility before release or after rejection. Assert no-option legacy calls still pass and LocalRuntime preserves owner-gate errors.

- [ ] **Step 2: Run RED**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
```

Expected: FAIL because arity-two registration, option-bearing functions, and `before_start/1` are absent.

- [ ] **Step 3: Implement minimal generic core code**

Add optional callback `@callback before_start(map()) :: :ok | {:error, term()}` to `Ezagent.Kind`. Keep `spawn/2` delegating to `spawn/3`; `spawn/3` copies only `:launch_context` into Kind params and retains current supervisor/readiness behavior. In `Kind.Server.init/1`, invoke `kind_module.before_start(args)` when exported, immediately after extracting URI and before snapshot load/registration; return `{:stop, {:before_start_failed, reason}}` on error. SpawnRegistry validates only `:launch_context`, invokes arity two with opts, invokes arity one only with `[]`, and otherwise fails closed. LocalRuntime delegates options without a redundant gate.

- [ ] **Step 4: Run GREEN and invariants**

Run Step 2, then:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/single_spawn_entry_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Expected: all selected tests pass with zero failures; Core has no new umbrella dependency or Agent-domain ownership-module reference, and the option is transported unchanged without inspection, persistence, logging, telemetry, or restart retention. Existing Core Workspace/plugin vocabulary remains allowed and unchanged-line baseline matches are not failures.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind.ex apps/ezagent_core/lib/ezagent/kind/server.ex apps/ezagent_core/lib/ezagent/spawn_registry.ex apps/ezagent_core/lib/ezagent/local_runtime.ex apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
git diff --cached --check
git commit -m "feat(core): transport opaque kind launch context"
```

### Task 2: LaunchAuthority registry and trusted Workspace issuer

**Files:**
- Create: `apps/ezagent_domain_agent/lib/ezagent/agent/launch_authority.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent_domain_agent/application.ex`
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/launch_authority.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/launch_authority_test.exs`
- Test: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/launch_authority_test.exs`

**Interfaces:**
- Consumes: `Store.get/1`, current `:starting` row fields, and claim `{id, start_claim_token}`.
- Produces: frozen register/resolve/acknowledge API; `PreStart.prepare/1` includes `launch_context: handle`.

- [ ] **Step 1: Write failing registry and issuer tests**

Test idempotent single registration, conflicting module rejection, missing/invalid implementation rejection. Create a starting Provision, call `TaskWorkspace.LaunchAuthority.issue(id, claim)`, resolve exact attempt/Agent/root/workspace, acknowledge once, then assert second resolve returns `:launch_context_consumed`. Wrong URI, expired/replaced claim, forged reference, and second acknowledgement must fail without returning identity values. Caller DOWN must not delete an issued handle.

- [ ] **Step 2: Run RED**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_authority_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/launch_authority_test.exs
```

Expected: FAIL because both modules and PreStart handle issuance are absent.

- [ ] **Step 3: Implement Agent-domain registered port**

Create a GenServer-backed `Ezagent.Agent.LaunchAuthority` with callbacks `resolve_launch/2` and `acknowledge_launch/1`, plus frozen facade signatures. Validate callbacks on registration; add the process to DomainAgent supervision before consumers. The module contains no Workspace schema import.

- [ ] **Step 4: Implement trusted issuer**

Create a supervised Workspace GenServer storing `%{make_ref() => %{id:, start_claim_token:, consumed?:}}`. `resolve_launch/2` re-reads the row and requires current unexpired `:starting` claim, exact Agent URI, non-empty attempt/root/workspace, and successful URI parsing. Return `issuer_ref: {handle, claim}`. Acknowledge atomically consumes the matching entry. Register the implementation at Workspace application start. PreStart issues only after claim and checkout verification; it does not write inventory.

- [ ] **Step 5: Run GREEN and commit**

Run Step 2; expect zero failures.

```bash
git add apps/ezagent_domain_agent/lib/ezagent/agent/launch_authority.ex apps/ezagent_domain_agent/lib/ezagent_domain_agent/application.ex apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/launch_authority.ex apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex apps/ezagent_domain_agent/test/ezagent/agent/launch_authority_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/launch_authority_test.exs
git diff --cached --check
git commit -m "feat(workspace): issue fenced agent launch context"
```

### Task 3: Transaction-aware exact inventory and lineage APIs

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory_entry.ex`
- Modify: `apps/ezagent_core/lib/ezagent/agent_lineage.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/creation_inventory_test.exs`
- Test: `apps/ezagent_core/test/ezagent/agent_lineage_test.exs`

**Interfaces:**
- Consumes: existing inventory unique key and lineage primary key.
- Produces: frozen exact APIs; transaction-aware writes never mutate ETS before commit.

- [ ] **Step 1: Write failing exactness/rollback tests**

Test insert, exact replay, same attempt/Agent with different root/workspace, and current lineage conflict. In one `Repo.transaction`, insert both facts then `Repo.rollback(:forced)`; assert neither durable row nor ETS lineage remains. Prove `record_exact` never reparents a conflicting Agent.

- [ ] **Step 2: Run RED**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/creation_inventory_test.exs apps/ezagent_core/test/ezagent/agent_lineage_test.exs
```

Expected: FAIL with undefined exact APIs.

- [ ] **Step 3: Implement exact APIs**

Add `@type t :: %__MODULE__{}` to CreationInventoryEntry. Accept Repo module as first argument so both writes share the caller transaction. Use insert/conflict queries that return `:exists` only for exact coordinates and explicit conflicts otherwise. Add `AgentLineage.publish_cache/2` for post-commit ETS publication; retain legacy overwrite behavior only in legacy `record/2`. `CreationInventory.exact/4` queries all coordinates and distinguishes absent from same-key conflict.

- [ ] **Step 4: Run GREEN and commit**

Run Step 2; expect zero failures and rollback leaves no cache entry.

```bash
git add apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory.ex apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory_entry.ex apps/ezagent_core/lib/ezagent/agent_lineage.ex apps/ezagent_domain_agent/test/ezagent/agent/creation_inventory_test.exs apps/ezagent_core/test/ezagent/agent_lineage_test.exs
git diff --cached --check
git commit -m "feat(agent): add exact ownership persistence APIs"
```

### Task 4: Winner child-init ownership transaction

**Files:**
- Create: `apps/ezagent_domain_agent/lib/ezagent/agent/launch_coordinator.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs`

**Interfaces:**
- Consumes: Tasks 1-3 frozen APIs.
- Produces: `LaunchCoordinator.consume_before_start/2` and `Entity.Agent.before_start/1`; success means receipt and lineage committed before live registration.

- [ ] **Step 1: Write failing transaction/barrier tests**

Register a fake authority returning exact facts. Put deterministic barriers before transaction commit and after commit but before return. Assert KindRegistry, ReadyGate, and snapshot are absent before commit. Kill the spawning caller after commit and assert inventory and lineage survive. Inject inventory and lineage failures separately and assert no actor, snapshot, receipt, lineage, or WorkspaceRegistry entry. Fail cache publication and authority acknowledgement; assert durable exact replay still succeeds.

- [ ] **Step 2: Run RED**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs
```

Expected: FAIL because coordinator and Agent `before_start/1` are absent.

- [ ] **Step 3: Implement validation and one Repo transaction**

`consume_before_start/2` resolves authority, validates exact Agent entity type, structural workspace equality, same-workspace root, and non-empty attempt. One `Repo.transaction` calls both Task 3 exact writes and rolls back on either error. After commit, publish AgentLineage cache and bind WorkspaceRegistry as a consistency cache; cache/ack failure cannot invalidate committed ownership. Exact replay returns the same receipt; conflict fails closed. `Entity.Agent.before_start/1` returns `:ok` without context, otherwise calls coordinator with `args.uri` and maps `{:ok, _}` to `:ok`. No ownership branch enters Kind.Server.

- [ ] **Step 4: Run GREEN and invariant**

Run Step 2 and:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/kind_provenance_test.exs
```

Expected: zero failures; committed facts precede actor visibility.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_agent/lib/ezagent/agent/launch_coordinator.ex apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs
git diff --cached --check
git commit -m "feat(agent): commit ownership in winner initialization"
```

### Task 5: Template and actual flavor option transport

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/template.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_deepseek_agent.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_deepseek_agent.ex`
- Modify: `apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex`
- Modify: `apps/ezagent_plugin_codex/lib/ezagent/template/codex_remote_agent.ex`
- Modify: `apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex`
- Modify: `apps/ezagent_plugin_py/lib/ezagent/template/py_agent.ex`
- Modify: `apps/ezagent_plugin_native/lib/ezagent/template/native_agent.ex`
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_test.exs`
- Test: `apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_test.exs`
- Test: `apps/ezagent_plugin_codex/test/ezagent/template/codex_remote_agent_test.exs`
- Test: `apps/ezagent_plugin_curl_agent/test/ezagent/template/curl_agent_test.exs`
- Create test: `apps/ezagent_plugin_py/test/ezagent/template/py_agent_launch_context_test.exs`
- Create test: `apps/ezagent_plugin_native/test/ezagent/template/native_agent_launch_context_test.exs`
- Test support: `apps/ezagent_domain_workspace/test/support/task_workspace_template_class.ex`

**Interfaces:**
- Consumes: option-aware Kind/LocalRuntime and Agent hook.
- Produces: optional `instantiate/4`; each real Agent Template forwards the identical reference to its existing Kind start seam.

- [ ] **Step 1: Write failing transport matrix**

Use the existing cc, codex, codex-remote, and curl Template tests plus the two new py/native files named above. For every listed Template, call `instantiate/4` with a unique handle and assert its existing spawn probe receives the identical reference. Assert `instantiate/3` remains unchanged. Add a Template lacking `instantiate/4` and assert context fails before Kind/config/sidecar effects. Change the Workspace support Template test expectation to atomic `:started | :already_started`, not Application-env freshness.

- [ ] **Step 2: Run RED plugin tests**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_test.exs apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_test.exs apps/ezagent_plugin_codex/test/ezagent/template/codex_remote_agent_test.exs apps/ezagent_plugin_curl_agent/test/ezagent/template/curl_agent_test.exs apps/ezagent_plugin_py/test/ezagent/template/py_agent_launch_context_test.exs apps/ezagent_plugin_native/test/ezagent/template/native_agent_launch_context_test.exs
```

Expected: FAIL because `instantiate/4` and option forwarding are absent.

- [ ] **Step 3: Implement callback and transport**

Add optional Template callback:

```elixir
@callback instantiate(template_name(), template_data(), URI.t(), keyword()) ::
  {:ok, [URI.t()]} | {:ok, [URI.t()], instantiate_meta()} | {:error, term()}
@optional_callbacks instantiate: 4
```

Each Template adds a distinct `instantiate/4` clause validating the sole `:launch_context` key and passes options separately through helpers. Never put it into `tmpl`. cc variants call `Kind.spawn(Entity.Agent, init_args, opts)`; codex local/remote call `LocalRuntime.ensure_started_detailed(agent_uri, opts)`; curl, py, and native call Kind.spawn/3. Preserve sidecar rollback and fresh/adopted branches. Change the final entity registration in DomainInstanceMessage Application to arity two, passing opts only for Agent URIs and rejecting non-empty opts for User URIs; retain the identity-domain early registration unchanged.

- [ ] **Step 4: Run GREEN and forbidden-runner scan**

Run the Step 2 command, then:

```bash
git diff -- apps/ezagent_plugin_cc apps/ezagent_plugin_codex apps/ezagent_plugin_curl_agent apps/ezagent_plugin_py apps/ezagent_plugin_native | rg '^\+.*(System\.cmd|Port\.open|MuonTrap|HTTPoison|Tesla|:httpc)' && exit 1 || true
```

Expected: all focused tests pass; scan has no added forbidden runner/client.

- [ ] **Step 5: Commit**

Stage exactly the Task 5 files actually changed, inspect `git diff --cached --name-only`, then:

```bash
git diff --cached --check
git commit -m "feat(agent): forward trusted launch context through templates"
```

### Task 6: TemplateSpawn fresh/adopt completion integration

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`
- Test: `apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`

**Interfaces:**
- Consumes: PreStart handle, Template `instantiate/4`, and `CreationInventory.exact/4`.
- Produces: Plan C fresh verifies the actor-init receipt; adopted completion creates or mutates no losing-attempt ownership fact.

- [ ] **Step 1: Write failing fresh/adopt/crash tests**

Fresh test asserts exact receipt exists before the post-instantiate completion barrier releases. Adopt test pre-creates an Agent with the same lineage/workspace, uses a different attempt, and asserts no losing receipt, no reparent/rebind, no sandbox/flavor/overlay mutation, and `:sidecar_start_not_fresh`. A claimed `fresh?: true` result with missing receipt fails `:ownership_receipt_missing` and never marks started.

- [ ] **Step 2: Run RED**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs
```

Expected: FAIL because PreStart prewrites inventory and TemplateSpawn still creates it after instantiate.

- [ ] **Step 3: Integrate receipt-backed path**

Remove `reserve_creation_identity/1` from PreStart. Carry `prepared.launch_context` separately from Template data and invoke `instantiate/4`; nil context retains legacy `instantiate/3`. Delete Plan C post-instantiate inventory write. Fresh Plan C calls `CreationInventory.exact/4` before remaining non-ownership obligations and skips legacy lineage/workspace writes already committed in actor init. Non-Plan-C fresh retains legacy obligations. Adopt finalizes PreStart before all ownership mutations and performs no request-derived sandbox/flavor update.

- [ ] **Step 4: Run GREEN and commit**

Run Step 2; expect zero failures and both deterministic crash/adopt assertions pass.

```bash
git add apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs
git diff --cached --check
git commit -m "fix(workspace): consume winner-owned creation receipt"
```

### Task 7: Receipt-gated recovery and ten-case crash/concurrency matrix

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/reconciler.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex`
- Test: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs`
- Test: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs`
- Create: `apps/ezagent_domain_workspace/test/integration/task_workspace_atomic_ownership_test.exs`

**Interfaces:**
- Consumes: exact receipt and existing retirement facade.
- Produces: recovery classification `{:owned, facts} | {:unowned, :creation_receipt_absent} | {:error, :creation_receipt_conflict}`. Only owned dispatches retirement.

- [ ] **Step 1: Write failing ten-case matrix with deterministic barriers**

Cover: winner commit before init return crash; instantiate return before completion crash; adopted same-lineage Agent; two concurrent attempts/exactly one receipt; each transaction write failure; cache publication failure/rehydrate; sidecar failure after receipt; Repo/BEAM-state restart; exact replay/coordinate conflict; expired starting row without receipt. Receipt cases assert retirement receives exact attempt/root/workspace. No-receipt cases assert no fake-retirement message and successful Provision/Git cleanup. Use explicit process messages sent by test-only authority and coordinator probes for every barrier; no sleeps.

- [ ] **Step 2: Run RED**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_atomic_ownership_test.exs
```

Expected: FAIL because recovery still assumes the prewritten handle and new crash/concurrency cases are not implemented.

- [ ] **Step 3: Implement receipt classification and recovery branches**

Store/Reconciler parse the row's exact URI coordinates and call `CreationInventory.exact/4`. Exact receipt returns owned facts; absent returns unowned; same-key mismatch returns conflict. Owned builds the existing CapBAC retirement context and calls `retire_spawned`. Unowned proceeds directly to exact Git cleanup without Agent dispatch. Conflict remains cleanup-pending with an auditable fixed blocker atom and never guesses ownership. Preserve active lease deferral and stale-token fencing.

- [ ] **Step 4: Run GREEN and commit**

Run Step 2 plus `apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`; expect zero failures and no timing-dependent assertions.

```bash
git add apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/reconciler.ex apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_atomic_ownership_test.exs
git diff --cached --check
git commit -m "fix(workspace): gate recovery retirement on exact receipt"
```

### Task 8: Structural boundaries, secrecy, and signed E2E

**Files:**
- Modify: `apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs`
- Modify: `apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs`
- Modify: `apps/ezagent_core/test/invariants/layer_purity_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/support/task_workspace_template_class.ex`

**Interfaces:**
- Consumes: completed launch/recovery path.
- Produces: CI gates for constructors, dependency direction, authored/logged data exclusion, plugin write prohibition, and signed provision→receipt→cleanup E2E.

- [ ] **Step 1: Write failing structural and E2E assertions**

Freeze approved production sites for `pre_start_ref:` and launch issuance. Assert Core has no exact references to Agent-domain ownership modules, no reverse umbrella dependency, and no code that destructures, reads fields from, serializes, logs, persists, snapshots, emits telemetry for, or retains `launch_context` across restart. Use AST/token-aware exact checks and changed-line ratchets; do not reject existing legitimate Workspace/plugin vocabulary. Assert plugins do not call inventory, lineage, WorkspaceRegistry, Provision/Store, or authority resolve/ack. Token-aware scans allow runtime option plumbing but reject `launch_context` in Template maps, JSON/YAML, Logger/telemetry, argv/env, config writers, or rendered errors. Assert no secret-like schema fields and no `20260717005000*`. Signed E2E pauses after receipt commit, verifies exact facts, releases completion, and proves cleanup retires exact attempt; adopted signed flow emits no retirement.

- [ ] **Step 2: Run RED**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs apps/ezagent_core/test/invariants/layer_purity_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs
```

Expected: new structural assertions fail until all boundaries and support transport are exact.

- [ ] **Step 3: Remove violations without widening broad allowlists**

Move any ownership call from plugins into coordinator/TemplateSpawn. Replace any data-map transport with separate keyword opts. Return fixed atoms such as `:invalid_launch_context`; never format the handle. Support Template implements both `instantiate/3` and `instantiate/4`, forwarding only opts. Structural allowlists contain exact file/function pairs, not directory-wide exemptions.

- [ ] **Step 4: Run GREEN and commit**

Run Step 2; expect zero failures and zero forbidden production sites.

```bash
git add apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs apps/ezagent_core/test/invariants/layer_purity_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs apps/ezagent_domain_workspace/test/support/task_workspace_template_class.ex
git diff --cached --check
git commit -m "test(git): lock atomic ownership boundaries"
```

### Task 9: Migration audit, full verification, and completion evidence

**Files:**
- Review only: `apps/ezagent_core/priv/repo_pg/migrations/20260715001000_agent_creation_inventory.exs`
- Review only by default; modify only after proven missing constraint: `apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs`
- Review: every file changed by Tasks 1-8

**Interfaces:**
- Consumes: all implementation commits.
- Produces: audited HEAD/commit list, schema decision, passing full verification, and no uncommitted implementation change.

- [ ] **Step 1: Prove schema decision**

```bash
rg -n 'creation_attempt_id|agent_uri|provenance_root_uri|workspace_uri' apps/ezagent_core/priv/repo_pg/migrations/20260715001000_agent_creation_inventory.exs apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs
find apps/ezagent_core/priv/repo_pg/migrations -name '20260717005000*.exs'
```

Expected: inventory already has all durable receipt coordinates and find has no output. If an exact constraint is demonstrably missing, first add a failing migration/schema test, observe RED, revise only `04000`, observe GREEN on a fresh test database, and commit `fix(db): constrain atomic ownership receipt`. Otherwise make no migration commit.

- [ ] **Step 2: Format and run focused suites**

```bash
SHELL=/bin/bash mix format --check-formatted
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/ezagent/agent_lineage_test.exs apps/ezagent_domain_agent/test/ezagent/agent/creation_inventory_test.exs apps/ezagent_domain_agent/test/ezagent/agent/launch_authority_test.exs apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/launch_authority_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_atomic_ownership_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs
```

Expected: formatter exits zero and all tests report zero failures.

- [ ] **Step 3: Run architecture gates and full precommit**

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs apps/ezagent_core/test/invariants/layer_purity_test.exs apps/ezagent_core/test/invariants/single_spawn_entry_test.exs apps/ezagent_core/test/invariants/kind_provenance_test.exs
SHELL=/bin/bash mix precommit
```

Expected: every command exits zero. Fix attributable failures with a new RED/GREEN cycle and narrow commit. Report unrelated baseline output and do not claim completion while precommit fails.

- [ ] **Step 4: Audit scope, secrets, HEAD, and commits**

```bash
git diff --check
git status --short
git log --oneline 256aec6d9..HEAD
git diff --name-only 256aec6d9..HEAD
git grep -nE 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|access_token|authorization_header' -- 'apps/ezagent_core/lib/**' 'apps/ezagent_domain_agent/lib/**' 'apps/ezagent_domain_workspace/lib/**' 'apps/ezagent_plugin_*/lib/**'
```

Expected: only the pre-existing unrelated handoff remains untracked; files match Tasks 1-8; no secret or handle rendering appears; commit list has one reviewable commit per task plus justified corrections.

- [ ] **Step 5: Return audited completion without integration action**

Return HEAD SHA, ordered commits, exact commands/results, migration decision, remaining status, and confirmation of no push/merge/rebase/deploy/PR. Do not create an empty completion commit.
