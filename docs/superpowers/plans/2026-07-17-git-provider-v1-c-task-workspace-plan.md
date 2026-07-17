# Git Provider V1-C Task Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision one authorized, isolated public-repository worktree per task generation and prove it is ready before any agent Template Class may start a sidecar.

**Architecture:** `GitTaskAccess` remains the sole authorization entry and calls a single registered `WorkspaceProvisionPort` only after exact signed-cap validation. Workspace Domain owns the durable state machine, anonymous Git execution, paths, cleanup, and boot recovery; core owns a generic Template pre-start hook that turns a ready provision reference into the only `cwd` passed to `instantiate/3`.

**Tech Stack:** Elixir 1.19, OTP 28, Ecto/PostgreSQL, `Ezagent.Lifecycle`, CapBAC dispatch, `Ezagent.Resource.FsResolver`, `Ezagent.Runtime.OsProcess`/erlexec, ExUnit.

## Global Constraints

- Public repositories only; `visibility: :private` returns `:private_checkout_not_supported` before a row, directory, Git process, adapter, HTTP, secret, or sidecar effect.
- The durable identity is exactly `workspace_uri + task_uri + generation`; every row has non-null `workspace_uri` and one unique identity constraint.
- `Ezagent.ActionSet.GitTaskAccess` actions are exactly extended with `:provision_workspace` and `:cleanup_workspace`; no wildcard/admin fallback.
- `WorkspaceProvisionPort` may be resolved and invoked only by `Ezagent.ActionSet.GitTaskAccess`; it is not a provider adapter and cannot select one.
- Workspace Domain must not call `Ezagent.DomainGit.AdapterRegistry` or a provider adapter callback.
- Core pre-start code is provider/task/Git/flavor-neutral; `plugin_cc` receives only the resolved `cwd` and contains no clone/worktree/provision-record code.
- Every production behavior uses `Ezagent.Lifecycle`; direct `use Ezagent.ActionSet`, direct Kind `DynamicSupervisor.start_child`, raw RPC/eval, and direct Cap slice writes are forbidden.
- Git subprocesses use the repository's erlexec-backed OS-process abstraction; never `System.cmd`, naked `Port.open`, MuonTrap, or shell interpolation.
- No Git credential, token, private key, credential ref, URL userinfo, askpass, credential helper, or secret environment enters the cache, worktree, agent, config dir, prompt, transcript, snapshot, audit, or blocker.
- No shared mutable cwd, `git stash`, cross-node lease, long-term pool, authenticated checkout, periodic comprehensive reaper, Kanban/UI work, deployment, push, or merge.
- Strict TDD: observe each RED failure before production code, then GREEN, then refactor; format touched files only and commit each task.

---

## File Map

**Domain Git contract and authorization**

- Create `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_port.ex`: closed request/result/error structs plus implementation behaviour.
- Create `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_port/request.ex`: closed request struct (separate file per the repository's no-nested-modules rule).
- Create `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_registry.ex`: single implementation registration and lookup; no authorization.
- Modify `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`: start the registry before task resources.
- Modify `apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex`: add the two action atoms and exact argument-policy comparisons.
- Modify `apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex`: declare actions, validate args, and call the port only after authorization.
- Modify `apps/ezagent_domain_git/lib/ezagent/domain_git/boot_registration.ex`: register the two new action capabilities during real application boot.

**Workspace Domain persistence and effects**

- Create `apps/ezagent_core/priv/repo_pg/migrations/20260717001000_create_git_task_workspace_provisions.exs`: durable per-tenant table and indexes.
- Create `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex`: Ecto schema and closed status set.
- Create `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex`: row-lock/CAS/lease transitions.
- Create `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/paths.ex`: deterministic tenant-scoped cache/worktree identities.
- Create `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex`: typed anonymous Git command plans and bounded results.
- Create `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provisioner.ex`: port implementation and state-machine orchestration.
- Create `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/reconciler.ex`: bounded boot recovery.
- Modify `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex`: register resource types/ports and start recovery.
- Modify `apps/ezagent_domain_workspace/mix.exs`: add one-way `ezagent_domain_git` dependency.

**Generic template gate**

- Create `apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex`: generic callback contract and single implementation registry.
- Modify `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`: accept a trusted opaque pre-start ref, prepare immediately before the single Template Class `instantiate/3` call, and report its outcome afterward.
- Create `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex`: provision-reference adapter implementing the generic hook.

**Focused and invariant tests**

- Add tests beside each module under the owning app.
- Create `apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`.
- Create `apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs`.
- Extend `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs` for exact-cap and no-effect proofs.

---

### Task 1: Freeze the Workspace Provision Port

**Files:**
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_port.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_port/request.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_registry.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/domain_git/workspace_provision_port_test.exs`
- Modify: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`

**Interfaces:**
- Consumes: validated `%Ezagent.Entity.GitTaskAccess{}` and canonical `task_uri`/`generation` supplied by Task 2.
- Produces: `WorkspaceProvisionPort.prepare/1`, `cleanup/1`, `register/1`, and `implementation/0` used by Tasks 2 and 5.

- [ ] **Step 1: Write RED contract and registry tests**

```elixir
defmodule Ezagent.DomainGit.WorkspaceProvisionPortTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.WorkspaceProvisionPort
  alias Ezagent.DomainGit.WorkspaceProvisionRegistry

  defmodule FakeProvisioner do
    @behaviour WorkspaceProvisionPort
    def prepare(request), do: {:ok, %{provision_id: request.provision_id, status: :ready}}
    def cleanup(request), do: {:ok, %{provision_id: request.provision_id, status: :cleaned}}
  end

  test "registers exactly one conforming implementation idempotently" do
    assert :ok = WorkspaceProvisionRegistry.register(FakeProvisioner)
    assert :ok = WorkspaceProvisionRegistry.register(FakeProvisioner)
    assert {:ok, FakeProvisioner} = WorkspaceProvisionRegistry.implementation()
    assert {:error, :conflicting_workspace_provisioner} =
             WorkspaceProvisionRegistry.register(__MODULE__)
  end

  test "request rejects caller-selected repository and path coordinates" do
    assert {:error, :unknown_fields} =
             WorkspaceProvisionPort.Request.new(%{
               task_access_uri: uri("resource://ws/git-task-access/a"),
               task_uri: uri("resource://ws/kanban-task/t"),
               generation: 1,
               operation: :prepare,
               local_path: "/tmp/forged"
             })
  end
end
```

- [ ] **Step 2: Run the RED test**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test/ezagent/domain_git/workspace_provision_port_test.exs`

Expected: FAIL because both modules are undefined.

- [ ] **Step 3: Implement the closed port and single registry**

```elixir
defmodule Ezagent.DomainGit.WorkspaceProvisionPort do
  @type operation :: :prepare | :cleanup

  @callback prepare(Request.t()) :: {:ok, map()} | {:error, term()}
  @callback cleanup(Request.t()) :: {:ok, map()} | {:error, term()}
end
```

Put the `Request` struct and its `new/1` closed-field validation in the separate
`workspace_provision_port/request.ex` file; its type is `%__MODULE__{task_access_uri:
URI.t(), task_uri: URI.t(), generation: non_neg_integer(), operation:
Ezagent.DomainGit.WorkspaceProvisionPort.operation(), provision_id: String.t()}`.
Do not nest it inside the behaviour module.

Implement the registry as an owner GenServer with idempotent same-module registration, conflicting-module rejection, behaviour/callback validation, and no callback execution during registration. Start it before `TaskAccessSupervisor`.

- [ ] **Step 4: Run GREEN tests and format touched files**

Run: `mix format apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_{port,registry}.ex apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex apps/ezagent_domain_git/test/ezagent/domain_git/workspace_provision_port_test.exs && SHELL=/bin/bash mix test apps/ezagent_domain_git/test/ezagent/domain_git/workspace_provision_port_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git
git commit -m "feat(git): add workspace provision port"
```

### Task 2: Authorize Provision and Cleanup Through GitTaskAccess

**Files:**
- Modify: `apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex`
- Modify: `apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex`
- Modify: `apps/ezagent_domain_git/lib/ezagent/domain_git/boot_registration.ex`
- Modify: `apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs`
- Modify: `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`
- Modify: `apps/ezagent_domain_git/test/ezagent_domain_git/application_boot_test.exs`

**Interfaces:**
- Consumes: Task 1 registry and request struct.
- Produces: `:provision_workspace` and `:cleanup_workspace` actions; no other module may invoke the registry.

- [ ] **Step 1: Write RED action and no-effect tests**

Add a fake registered provisioner that sends `{:workspace_effect, operation}` to the test process. Assert:

```elixir
test "authorized exact task instance provisions through the registered port", fixture do
  invocation = invocation(fixture, :provision_workspace, %{
    task_uri: fixture.task_uri,
    generation: fixture.policy.generation
  })

  assert {:ok, %{status: :ready}} = Ezagent.Router.dispatch(invocation)
  assert_receive {:workspace_effect, :prepare}
end

test "wrong grantee produces no workspace effect" do
  assert {:error, :unauthorized} = Ezagent.Router.dispatch(wrong_grantee_invocation())
  refute_receive {:workspace_effect, _}
end
```

Also assert wrong workspace, wrong instance, wrong generation, unsigned artifact, unknown args, and a working-agent attempt to call `:cleanup_workspace` all fail before the fake callback.

- [ ] **Step 2: Run RED tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`

Expected: FAIL because the actions are absent.

- [ ] **Step 3: Add exact actions and post-auth port invocation**

Declare:

```elixir
action(:provision_workspace,
  args: %{task_uri: :term, generation: :integer},
  returns: :term,
  caps: [:provision_workspace],
  modes: [:call],
  description: "Prepare the exact task generation workspace"
)

action(:cleanup_workspace,
  args: %{task_uri: :term, generation: :integer},
  returns: :term,
  caps: [:cleanup_workspace],
  modes: [:call],
  description: "Clean the exact task generation workspace"
)
```

Construct `provision_id` as a SHA-256 lowercase hex digest of canonical workspace URI, canonical task URI, and decimal generation separated by `0x00`. Build the Task 1 request only after `authorize_receiver/3`, then resolve/call the port. Extend the policy action allowlist and reject generation mismatch before registry lookup.

- [ ] **Step 4: Run GREEN tests and the structural source assertion**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`

Expected: all tests pass and negative cases receive no effect message.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git
git commit -m "feat(git): authorize task workspace lifecycle"
```

### Task 3: Add the Durable Provision Record and Locked Store

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260717001000_create_git_task_workspace_provisions.exs`
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex`
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex`
- Create: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`
- Modify: `apps/ezagent_domain_workspace/mix.exs`

**Interfaces:**
- Consumes: core Repo and Task 1 `provision_id`.
- Produces: `Store.create_planned/1`, `claim_provision/2`, `mark_ready/3`, `claim_start/2`, `mark_started/2`, `request_cleanup/2`, `claim_cleanup/2`, `mark_cleaned/2`, and `list_recoverable/1`.

- [ ] **Step 1: Write RED store transition tests**

```elixir
test "identity is idempotent and conflicting immutable fields fail" do
  assert {:ok, first} = Store.create_planned(attrs())
  assert {:ok, same} = Store.create_planned(attrs())
  assert first.id == same.id
  assert {:error, :conflicting_provision_identity} =
           Store.create_planned(%{attrs() | repository_uri: "resource://ws/git-repository/other"})
end

test "expired lease is reclaimable and stale token cannot commit ready" do
  {:ok, row} = Store.create_planned(attrs())
  {:ok, first} = Store.claim_provision(row.id, now: at(0), lease_seconds: 30)
  assert {:error, :provision_already_claimed} =
           Store.claim_provision(row.id, now: at(10), lease_seconds: 30)
  {:ok, second} = Store.claim_provision(row.id, now: at(31), lease_seconds: 30)
  assert {:error, :provision_lease_lost} = Store.mark_ready(row.id, first.claim_token, ready_attrs())
  assert {:ok, ready} = Store.mark_ready(row.id, second.claim_token, ready_attrs())
  assert ready.status == :ready
end
```

Add concurrent `Task.async_stream(..., timeout: :infinity)` tests proving one provision claim and one start claim win.

- [ ] **Step 2: Run RED store test**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`

Expected: FAIL because the schema/table/store are absent.

- [ ] **Step 3: Implement migration, schema, and locked transitions**

The migration creates `git_task_workspace_provisions` with non-null identity/policy fingerprint/status/version fields, nullable lease/start/cleanup fields, timestamps, a unique index on `[:workspace_uri, :task_uri, :generation]`, and indexes on `[:status, :lease_until]` and `[:workspace_uri, :status]`.

Use `Ecto.Enum` values:

```elixir
@statuses [:planned, :provisioning, :ready, :sidecar_started, :blocked,
           :cleanup_pending, :cleaned]
```

Every transition loads the row in `Repo.transaction/1` with `lock: "FOR UPDATE"`, checks status/token/version, and writes the next state. Store only safe blocker atoms as strings; do not persist raw Git output.

- [ ] **Step 4: Migrate test DB and run GREEN tests**

Run: `SHELL=/bin/bash MIX_ENV=test mix ecto.migrate && SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`

Expected: all store tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/priv/repo_pg/migrations/20260717001000_create_git_task_workspace_provisions.exs apps/ezagent_domain_workspace
git commit -m "feat(workspace): persist task workspace lifecycle"
```

### Task 4: Derive Safe Paths and Execute Anonymous Git Plans

**Files:**
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/paths.ex`
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex`
- Create: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/paths_test.exs`
- Create: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`

**Interfaces:**
- Consumes: canonical workspace/repository URI, base ref, provision id, allowed head ref.
- Produces: safe cache/worktree paths and `GitRunner.prepare/1`, `remove/1`, `verify/1`.

- [ ] **Step 1: Write RED path and real-local-Git tests**

Create a temporary public-style local bare origin fixture without credentials. Assert deterministic paths stay beneath the registered task-workspace root, two generations differ, traversal inputs fail, and no command plan contains shell text.

```elixir
test "private repository fails before runner invocation" do
  request = request(visibility: :private)
  assert {:error, :private_checkout_not_supported} = GitRunner.prepare(request)
  refute_received {:os_process_started, _}
end

test "prepare creates an isolated worktree without credential settings" do
  assert {:ok, ready} = GitRunner.prepare(public_fixture_request())
  assert File.dir?(ready.worktree_path)
  assert ready.argv_history |> List.flatten() |> Enum.all?(&(not secret_option?(&1)))
  assert :ok = GitRunner.verify(ready)
end
```

- [ ] **Step 2: Run RED tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/{paths,git_runner}_test.exs`

Expected: FAIL because modules are undefined.

- [ ] **Step 3: Implement registered path resolution and argv-only Git execution**

Register a tenant-scoped resource type such as `git-task-workspaces` with a unique backend component. Resolve paths through `Ezagent.Resource.FsResolver` using workspace authority. Encode repository/cache identity and provision id as safe single components.

Build argv lists only, including credential hardening:

```elixir
["-c", "credential.helper=", "-c", "core.askPass=", "clone", "--bare", remote, cache]
["--git-dir", cache, "worktree", "add", "--detach", worktree, base_ref]
```

Set `GIT_TERMINAL_PROMPT=0`, an empty allowlisted environment, bounded stdout/stderr, and a deadline. The production runner is an owner process that traps exits, starts argv through `Ezagent.Runtime.OsProcess.spawn/2`, accumulates only capped output, stops the erlexec pid on deadline/overflow, and always calls `OsProcess.stop/1` during termination. Reject URL userinfo and non-HTTPS/public fixture transports in production mode. Tests may inject an argv executor and local fixture transport; production uses `Ezagent.Runtime.OsProcess` only.

- [ ] **Step 4: Run GREEN tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/{paths,git_runner}_test.exs`

Expected: all tests pass; no credential-bearing option/environment appears.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_workspace
git commit -m "feat(workspace): prepare anonymous task worktrees"
```

### Task 5: Implement the Provision State Machine

**Files:**
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provisioner.ex`
- Create: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex`

**Interfaces:**
- Consumes: Tasks 1, 3, and 4.
- Produces: the registered `WorkspaceProvisionPort` implementation and ready provision facts.

- [ ] **Step 1: Write RED idempotency, drift, and failure tests**

Tests inject a fake Git runner and assert:

```elixir
test "duplicate prepare converges on one row and one worktree effect" do
  results =
    1..8
    |> Task.async_stream(fn _ -> Provisioner.prepare(request()) end, timeout: :infinity)
    |> Enum.map(fn {:ok, result} -> result end)

  assert Enum.uniq(results) |> length() == 1
  assert_receive {:git_prepare, _}, 1_000
  refute_receive {:git_prepare, _}
end

test "policy drift blocks before filesystem effect" do
  seed_record(repository_uri: old_repository_uri())
  assert {:error, :task_policy_mismatch} = Provisioner.prepare(request())
  refute_receive {:git_prepare, _}
end
```

Cover private visibility, lease loss after Git success, Git error normalization, cancelled row, and a path owned by another active record.

- [ ] **Step 2: Run RED tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs`

Expected: FAIL because `Provisioner` is undefined.

- [ ] **Step 3: Implement the minimal orchestration**

`prepare/1` must load the live `GitTaskAccess` slice, revalidate it, compare task URI/generation/repository fingerprints, reject private visibility, create/load planned state, claim a lease, call `GitRunner.prepare/1`, verify, and commit ready with the same claim token. A losing duplicate waits/polls by state with a bounded deadline rather than running a second Git effect.

Register the module with `WorkspaceProvisionRegistry` during Workspace Domain boot; conflicting registration fails application start.

- [ ] **Step 4: Run GREEN tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_workspace
git commit -m "feat(workspace): orchestrate task workspace readiness"
```

### Task 6: Add the Generic Template Pre-Start Contract

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex`
- Create: `apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`
- Modify: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

**Interfaces:**
- Consumes: an optional opaque `:pre_start_ref` supplied through the trusted `spawn_from_template_content/5` options, never recipe/template data.
- Produces: `PreStart.prepare/1`, `complete/2`, and a wrapper around the existing single Template Class `instantiate/3` call.

- [ ] **Step 1: Write RED ordering and callback tests**

```elixir
test "does not instantiate when pre-start preparation fails" do
  register_pre_start(fn _ -> {:error, :workspace_not_ready} end)
  assert {:error, :workspace_not_ready} = provision_and_instantiate(data_with_ref())
  refute_receive :instantiate_called
end

test "injects resolved cwd and reports instantiate success" do
  register_pre_start(fn _ -> {:ok, %{cwd: "/safe/task", claim: "claim-1"}} end)
  assert {:ok, [_]} = provision_and_instantiate(data_with_ref())
  assert_receive {:instantiate_called, %{"cwd" => "/safe/task"}}
  assert_receive {:pre_start_complete, "claim-1", :ok}
end
```

Also cover instantiate error, raise/exit, no-ref unchanged behavior, missing implementation fail-closed, and double completion rejection.

- [ ] **Step 2: Run RED tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs`

Expected: FAIL because `PreStart` is undefined and the wrapper does not gate.

- [ ] **Step 3: Implement the generic contract and wrapper ordering**

The core module accepts opaque refs and returns `%{cwd: binary, claim: opaque}`. It must not contain the strings/modules `Git`, `TaskWorkspace`, `GitTaskAccess`, `plugin_cc`, or provider names. `TemplateSpawn` removes `:pre_start_ref` from trusted spawn options, calls `prepare`, overwrites only the transient Template Class data's `"cwd"`, calls `instantiate/3` inside `try/catch`, and calls `complete(claim, outcome)` exactly once. The ref is never merged into persisted AgentTemplate content or plugin data.

- [ ] **Step 4: Run GREEN and existing template tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/template apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
git commit -m "feat(core): gate template start on readiness"
```

### Task 7: Bind Ready Records to One Sidecar Start

**Files:**
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex`
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/agent_start.ex`
- Create: `apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex`

**Interfaces:**
- Consumes: Task 3 start claims and Task 6 generic hook.
- Produces: authoritative `cwd` injection and `ready -> sidecar_started` completion.

- [ ] **Step 1: Write RED integration tests with a probe Template Class**

Assert an unready/missing/private/cancelled generation never calls the probe's `instantiate/3`; ready state calls it with the stored canonical path; 20 concurrent instantiate attempts produce one success/start claim; instantiate failure moves the record to `cleanup_pending`; a consumed token cannot retry before reconciliation.

```elixir
test "two starts cannot claim the same ready generation" do
  results = concurrent_starts(20, ready_template_data())
  assert Enum.count(results, &match?({:ok, _}, &1)) == 1
  assert Enum.count(results, &match?({:error, :sidecar_start_already_consumed}, &1)) == 19
  assert_receive {:instantiate_called, canonical_worktree_path()}
  refute_receive {:instantiate_called, _}
end
```

- [ ] **Step 2: Run RED test**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`

Expected: FAIL because the workspace pre-start implementation is absent.

- [ ] **Step 3: Implement claim/complete and authoritative reference threading**

`AgentStart.start/5` is the sole constructor of an opaque `pre_start_ref` struct with exactly `provision_id`, task-access URI, task URI, and generation. It delegates to `Ezagent.Entity.Agent.TemplateSpawn.spawn_from_template_content/5` with the ref in options. `PreStart.prepare/1` locks/claims ready state, re-verifies the filesystem proof, and returns the stored path. `complete/2` marks started only on successful instantiate; every error/raise/exit requests cleanup.

Do not modify `RecipeMaterializer` or accept arbitrary recipe/template fields as provision references. Ordinary recipes keep current behavior; only the governed Workspace Domain start path may construct the ref and pass the option.

- [ ] **Step 4: Run GREEN integration and cc-headless parameter tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs apps/ezagent_plugin_cc/test/ezagent/template/cc_headless_agent_test.exs`

Expected: all tests pass; cc-headless remains unaware of provision modules.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_workspace
git commit -m "feat(workspace): claim task cwd before sidecar start"
```

### Task 8: Implement Cleanup and Bounded Boot Recovery

**Files:**
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/reconciler.ex`
- Create: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provisioner.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex`

**Interfaces:**
- Consumes: Task 3 cleanup claims, Task 4 exact removal, sanctioned agent lifecycle.
- Produces: idempotent terminal cleanup and one boot scan of expired/recoverable rows.

- [ ] **Step 1: Write RED cleanup/recovery race tests**

Cover cancellation during Git prepare, cancellation after ready but before start, cancellation racing start claim, failed instantiate, expired provision lease, expired cleanup lease, missing ready worktree, and an unrelated directory beneath the root.

```elixir
test "reconciler never deletes an unrecorded directory" do
  rogue = create_unrecorded_directory_under_root()
  assert :ok = Reconciler.run_once(now: now())
  assert File.dir?(rogue)
end

test "stale provision worker cannot restore ready after cancellation" do
  {row, stale_token} = claim_then_cancel()
  assert {:error, :provision_lease_lost} = Store.mark_ready(row.id, stale_token, ready_attrs())
  assert {:ok, cleaned} = Provisioner.cleanup(cleanup_request(row))
  assert cleaned.status == :cleaned
end
```

- [ ] **Step 2: Run RED tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs`

Expected: FAIL because reconciler/cleanup behavior is incomplete.

- [ ] **Step 3: Implement minimal cleanup and one boot scan**

Invalidate unused start token and set `cleanup_pending` atomically; use sanctioned lifecycle termination, verify the derived path equals the recorded path, run Git worktree removal, verify absence, then mark cleaned with the matching cleanup token. At boot, process only expired `provisioning`, `cleanup_pending`, and invalid `ready` rows with a configured finite batch. Do not enumerate/delete raw filesystem paths.

- [ ] **Step 4: Run GREEN tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_workspace
git commit -m "feat(workspace): recover task workspace cleanup"
```

### Task 9: Add Structural and End-to-End Invariant Proofs

**Files:**
- Create: `apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs`
- Modify: `apps/ezagent_domain_git/test/architecture/dependency_boundary_test.exs`
- Modify: `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`

**Interfaces:**
- Consumes: all Plan C production interfaces.
- Produces: tests that fail if authorization, ownership, secret, or start ordering regresses.

- [ ] **Step 1: Write RED structural scans before allowlisting new code**

The source-tree tests must define concrete helpers using `Path.wildcard/1`, `File.read!/1`, and exact relative paths, then assert:

```elixir
refute_source_under("apps/ezagent_plugin_cc/lib", ~r/WorkspaceProvision|TaskWorkspace|task_workspace_provisions|git\s+(clone|worktree)/)
refute_source_under("apps/ezagent_domain_workspace/lib", ~r/AdapterRegistry|\.create_change_request\(|\.resolve_repository\(/)
assert_only_path_calls("WorkspaceProvisionRegistry.implementation", [
  "apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex"
])
refute_schema_fields(~w[token credential secret private_key authorization_header environment]a)
```

Use this helper shape in the test file rather than relying on imaginary shared test helpers:

```elixir
defp source_files(root), do: Path.wildcard(Path.join(root, "**/*.{ex,exs}"))

defp refute_source_under(root, regex) do
  offenders = for path <- source_files(root), Regex.match?(regex, File.read!(path)), do: path
  assert offenders == []
end

defp assert_only_path_calls(needle, allowed) do
  this_test = "apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs"

  callers =
    for path <- Path.wildcard("apps/*/{lib,test}/**/*.{ex,exs}"),
        path != this_test,
        String.contains?(File.read!(path), needle),
        do: path

  assert Enum.sort(callers) == Enum.sort(allowed)
end

defp refute_schema_fields(fields) do
  schema = File.read!("apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex")
  Enum.each(fields, fn field -> refute schema =~ "field :#{field}" end)
end
```

Add a single integration proof that uses a real signed receiver-bound cap, real `GitTaskAccess`, real store, local public Git fixture, probe sidecar Template Class, and terminal cleanup.

- [ ] **Step 2: Run RED invariant tests**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs apps/ezagent_domain_git/test/architecture/dependency_boundary_test.exs`

Expected: FAIL until all call sites/file allowlists match the intended boundary.

- [ ] **Step 3: Make the minimum production/test adjustments**

Move any violating call behind the correct port or private module; do not weaken regexes or add broad allowlists. Ensure unauthorized integration cases assert zero row count, zero directory entries, zero process probe messages, and zero sidecar messages.

- [ ] **Step 4: Run the complete focused Plan C suite**

Run:

```bash
SHELL=/bin/bash mix test \
  apps/ezagent_domain_git/test/ezagent/domain_git/workspace_provision_port_test.exs \
  apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs \
  apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs \
  apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs
```

Expected: all tests pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git/test apps/ezagent_domain_workspace/test
git commit -m "test(workspace): enforce task workspace boundaries"
```

### Task 10: Final Verification and Return Evidence

**Files:**
- Modify only if needed: Plan C return artifact under `docs/together/2026-07-17/returns/`

**Interfaces:**
- Consumes: Tasks 1–9.
- Produces: fresh machine evidence and a dev-together return; no push/merge/deploy.

- [ ] **Step 1: Format only touched Elixir files and check the full tree**

Run:

```bash
mix format \
  apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_port.ex \
  apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_provision_registry.ex \
  apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex \
  apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex \
  apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex \
  apps/ezagent_domain_git/test/ezagent/domain_git/workspace_provision_port_test.exs \
  apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs \
  apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs \
  apps/ezagent_domain_git/test/architecture/dependency_boundary_test.exs \
  apps/ezagent_core/priv/repo_pg/migrations/20260717001000_create_git_task_workspace_provisions.exs \
  apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex \
  apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs \
  apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/*.ex \
  apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex \
  apps/ezagent_domain_workspace/mix.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/*.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs \
  apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs \
  apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex \
  apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
mix format --check-formatted
```

Expected: exit 0 without unrelated formatter churn.

- [ ] **Step 2: Run affected app suites**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_git/test apps/ezagent_domain_workspace/test apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs apps/ezagent_plugin_cc/test/ezagent/template/cc_headless_agent_test.exs`

Expected: zero failures.

- [ ] **Step 3: Run static and invariant gates**

Run:

```bash
SHELL=/bin/bash mix ezagent.arch.scan
SHELL=/bin/bash mix ezagent.doc.scan
SHELL=/bin/bash mix ezagent.uri_query.scan
SHELL=/bin/bash mix ezagent.check_invariants
SHELL=/bin/bash mix ezagent.check_invariants.lifecycle
```

Expected: every command exits 0; any pre-existing baseline failure is recorded with exact output and not silently attributed to Plan C.

- [ ] **Step 4: Run project precommit**

Run: `SHELL=/bin/bash mix precommit`

Expected: exit 0. If the known branch baseline failures remain, stop the return as blocked or obtain lead adjudication; do not claim the machine gate is green.

- [ ] **Step 5: Reconcile every design DoD line and write the return**

Create `docs/together/2026-07-17/returns/gaga-git-provider-plan-c.md` with `returned_at`, deadline fields, per-line DoD evidence, commands/output, commits, known deferrals, and method friction. State explicitly that private checkout, credentials, Plan D, Plan E, deployment, and merge remain absent.

- [ ] **Step 6: Commit the return artifact**

```bash
git add docs/together/2026-07-17/returns/gaga-git-provider-plan-c.md
git commit -m "docs(together): return git provider plan c"
```

Do not push until the lead/user authorizes it.
