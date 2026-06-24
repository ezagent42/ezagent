# Workspace Locality Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a behavior-preserving workspace owner gate that blocks fake non-owner dispatch, spawn, and session creation in tests, then add plugin bypass invariants.

**Architecture:** PR 1 adds `RuntimeIdentity`, `WorkspacePlacement`, and `WorkspaceOwnerGate` in core, then wires the gate into dispatch, spawn, and session creation chokepoints. PR 2 adds architecture tests and plugin contract documentation so future plugin code cannot bypass the core gate without a centralized exception.

**Tech Stack:** Elixir, Phoenix umbrella, ExUnit, Ecto sandbox, local ETS registries, existing `Ezagent.URI.workspace_of/1` and `Ezagent.Capability.workspace_of/1` helpers.

---

## Branch Workflow

- Base branch/worktree: `/Users/h2oslabs/Workspace/esr-ng/.worktrees/remove-localization-assumption`
- Integration target: `remove-localization-assumption`
- PR 1 branch: `feat/workspace-locality-core-gate`
- PR 2 branch: `feat/workspace-locality-plugin-invariants`
- Both PRs target `remove-localization-assumption`.
- After both land, return `remove-localization-assumption` to lead via dev-together.

## File Map

PR 1 creates:

- `apps/ezagent_core/lib/ezagent/runtime_identity.ex` — current runtime identity abstraction.
- `apps/ezagent_core/lib/ezagent/workspace_placement.ex` — owner resolver facade with local default resolver and test override support.
- `apps/ezagent_core/lib/ezagent/workspace_placement/local_resolver.ex` — default resolver returning current runtime.
- `apps/ezagent_core/lib/ezagent/workspace_owner_gate.ex` — gate API, enforce/observe modes, workspace extraction, telemetry, and exemptions.
- `apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs` — unit coverage.
- `apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs` — core dispatch/spawn invariants.
- `apps/ezagent_domain_session/test/integration/session_creator_workspace_owner_gate_test.exs` — session create non-owner invariant.

PR 1 modifies:

- `apps/ezagent_core/lib/ezagent/invocation.ex` — gate before idempotency/local lookup/lazy spawn for workspace-bound targets.
- `apps/ezagent_core/lib/ezagent/spawn_registry.ex` — gate before `KindRegistry.lookup/1` and spawn function lookup.
- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex` — gate before node-local lock and materialization.

PR 2 creates:

- `apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs` — plugin bypass scan.
- `docs/superpowers/specs/2026-06-24-workspace-locality-plugin-contract.md` — plugin authoring contract and exception list.

## PR 1: Core Locality Gate

### Task 1: Runtime Identity And Placement Facade

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/runtime_identity.ex`
- Create: `apps/ezagent_core/lib/ezagent/workspace_placement.ex`
- Create: `apps/ezagent_core/lib/ezagent/workspace_placement/local_resolver.ex`
- Test: `apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs`

- [ ] **Step 1: Write failing unit tests for runtime identity and local placement**

Add this test module:

```elixir
defmodule Ezagent.WorkspaceOwnerGateTest do
  use ExUnit.Case, async: false

  alias Ezagent.{RuntimeIdentity, WorkspacePlacement}

  setup do
    previous_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    previous_placement = Application.get_env(:ezagent_core, WorkspacePlacement)

    on_exit(fn ->
      restore_env(RuntimeIdentity, previous_identity)
      restore_env(WorkspacePlacement, previous_placement)
    end)

    :ok
  end

  test "RuntimeIdentity.current/0 can be overridden in tests" do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
    assert RuntimeIdentity.current() == "test-node-a"
  end

  test "local WorkspacePlacement resolver owns every workspace by default" do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert {:ok, "test-node-a"} = WorkspacePlacement.owner_of(workspace_uri)
    assert WorkspacePlacement.local_owner?(workspace_uri)
  end

  defp restore_env(_module, nil), do: Application.delete_env(:ezagent_core, _module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mix test apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs
```

Expected: compile failure for missing `Ezagent.RuntimeIdentity` or `Ezagent.WorkspacePlacement`.

- [ ] **Step 3: Implement runtime identity and placement facade**

Create `apps/ezagent_core/lib/ezagent/runtime_identity.ex`:

```elixir
defmodule Ezagent.RuntimeIdentity do
  @moduledoc """
  Runtime identity used by workspace ownership gates.

  The identity is a deployment/runtime identifier, not business domain state.
  Tests may override it through application env.
  """

  @spec current() :: term()
  def current do
    case Application.get_env(:ezagent_core, __MODULE__, [])[:runtime_id] do
      nil -> node()
      runtime_id -> runtime_id
    end
  end
end
```

Create `apps/ezagent_core/lib/ezagent/workspace_placement.ex`:

```elixir
defmodule Ezagent.WorkspacePlacement do
  @moduledoc """
  Workspace ownership resolver facade.

  The first implementation is local-only: every workspace is owned by the
  current runtime. Tests can inject a resolver to simulate non-owner runtimes.
  """

  alias Ezagent.WorkspacePlacement.LocalResolver

  @type owner :: term()

  @callback owner_of(URI.t()) :: {:ok, owner()} | {:error, term()}

  @spec owner_of(URI.t()) :: {:ok, owner()} | {:error, term()}
  def owner_of(%URI{} = workspace_uri), do: resolver().owner_of(workspace_uri)

  @spec local_owner?(URI.t()) :: boolean()
  def local_owner?(%URI{} = workspace_uri) do
    case owner_of(workspace_uri) do
      {:ok, owner} -> owner == Ezagent.RuntimeIdentity.current()
      {:error, _} -> false
    end
  end

  @spec resolver() :: module()
  def resolver do
    Application.get_env(:ezagent_core, __MODULE__, [])[:resolver] || LocalResolver
  end
end
```

Create `apps/ezagent_core/lib/ezagent/workspace_placement/local_resolver.ex`:

```elixir
defmodule Ezagent.WorkspacePlacement.LocalResolver do
  @moduledoc """
  Default resolver for the current single-runtime deployment model.
  """

  @behaviour Ezagent.WorkspacePlacement

  @impl true
  def owner_of(%URI{scheme: "workspace"}) do
    {:ok, Ezagent.RuntimeIdentity.current()}
  end
end
```

- [ ] **Step 4: Run the unit test and verify GREEN**

Run:

```bash
mix test apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs
```

Expected: tests pass.

- [ ] **Step 5: Commit PR 1 Task 1**

```bash
git add apps/ezagent_core/lib/ezagent/runtime_identity.ex \
  apps/ezagent_core/lib/ezagent/workspace_placement.ex \
  apps/ezagent_core/lib/ezagent/workspace_placement/local_resolver.ex \
  apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs
git commit -m "feat(core): add workspace placement facade"
```

### Task 2: Workspace Owner Gate API

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/workspace_owner_gate.ex`
- Modify: `apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs`

- [ ] **Step 1: Add failing gate behavior tests**

Append fake resolvers and tests:

```elixir
defmodule RemoteResolver do
  @behaviour Ezagent.WorkspacePlacement
  def owner_of(%URI{scheme: "workspace"}), do: {:ok, "remote-node"}
end

defmodule UnknownResolver do
  @behaviour Ezagent.WorkspacePlacement
  def owner_of(%URI{scheme: "workspace"}), do: {:error, :not_found}
end

test "assert_local_owner/2 returns :ok when current runtime owns workspace" do
  Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
  workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

  assert :ok =
           Ezagent.WorkspaceOwnerGate.assert_local_owner(
             workspace_uri,
             {:dispatch, Ezagent.URI.new!("session://team-alpha/default/main")}
           )
end

test "assert_local_owner/2 fails closed for a remote owner in enforce mode" do
  Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
  Application.put_env(:ezagent_core, WorkspacePlacement, resolver: RemoteResolver)
  workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
  target_uri = Ezagent.URI.new!("session://team-alpha/default/main")

  assert {:error,
          {:not_workspace_owner, ^workspace_uri, "remote-node", "test-node-a",
           {:dispatch, ^target_uri}}} =
           Ezagent.WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:dispatch, target_uri})
end

test "assert_local_owner/2 emits violation but continues in observe mode" do
  Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
  Application.put_env(:ezagent_core, WorkspacePlacement, resolver: RemoteResolver, mode: :observe)
  workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
  target_uri = Ezagent.URI.new!("session://team-alpha/default/main")
  handler_id = {__MODULE__, self(), :owner_gate_violation}

  :ok =
    :telemetry.attach(
      handler_id,
      [:ezagent, :workspace_owner_gate, :violation],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:owner_gate_violation, event, measurements, metadata})
      end,
      self()
    )

  try do
    assert :ok = Ezagent.WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:dispatch, target_uri})
  after
    :telemetry.detach(handler_id)
  end

  assert_receive {:owner_gate_violation, [:ezagent, :workspace_owner_gate, :violation], %{},
                  %{workspace_uri: ^workspace_uri, expected_owner: "remote-node", current_runtime: "test-node-a"}}
end

test "assert_local_owner/2 fails closed when owner is unknown" do
  Application.put_env(:ezagent_core, WorkspacePlacement, resolver: UnknownResolver)
  workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

  assert {:error, {:workspace_owner_unknown, ^workspace_uri, {:spawn, ^workspace_uri}}} =
           Ezagent.WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:spawn, workspace_uri})
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mix test apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs
```

Expected: compile failure for missing `Ezagent.WorkspaceOwnerGate`.

- [ ] **Step 3: Implement gate API**

Create `apps/ezagent_core/lib/ezagent/workspace_owner_gate.ex`:

```elixir
defmodule Ezagent.WorkspaceOwnerGate do
  @moduledoc """
  Enforces that workspace-bound runtime work happens on the workspace owner.
  """

  @type operation ::
          {:dispatch, URI.t()}
          | {:spawn, URI.t()}
          | {:session_create, URI.t()}
          | {:session_repair, URI.t()}
          | {:plugin_ingress, term(), term()}
          | {:mcp_join, URI.t()}
          | {:resource_access, URI.t()}
          | term()

  @spec assert_local_owner(URI.t(), operation()) :: :ok | {:error, term()}
  def assert_local_owner(%URI{scheme: "workspace"} = workspace_uri, operation) do
    current = Ezagent.RuntimeIdentity.current()

    case Ezagent.WorkspacePlacement.owner_of(workspace_uri) do
      {:ok, ^current} ->
        :ok

      {:ok, expected} ->
        violation = {:not_workspace_owner, workspace_uri, expected, current, operation}
        handle_violation(workspace_uri, expected, current, operation, violation)

      {:error, _reason} ->
        violation = {:workspace_owner_unknown, workspace_uri, operation}
        handle_violation(workspace_uri, nil, current, operation, violation)
    end
  end

  def assert_local_owner(other, operation) do
    {:error, {:workspace_required, operation, other}}
  end

  @spec assert_local_owner_for_uri(URI.t(), operation()) :: :ok | {:error, term()}
  def assert_local_owner_for_uri(%URI{} = uri, operation) do
    case Ezagent.URI.workspace_of(uri) do
      %URI{} = workspace_uri -> assert_local_owner(workspace_uri, operation)
      :any -> :ok
    end
  end

  defp handle_violation(workspace_uri, expected, current, operation, violation) do
    mode = mode()

    :telemetry.execute(
      [:ezagent, :workspace_owner_gate, :violation],
      %{},
      %{
        workspace_uri: workspace_uri,
        operation: operation,
        mode: mode,
        expected_owner: expected,
        current_runtime: current,
        result: violation
      }
    )

    case mode do
      :observe -> :ok
      :enforce -> {:error, violation}
    end
  end

  defp mode do
    Application.get_env(:ezagent_core, Ezagent.WorkspacePlacement, [])[:mode] || :enforce
  end
end
```

- [ ] **Step 4: Run the gate test and verify GREEN**

Run:

```bash
mix test apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit PR 1 Task 2**

```bash
git add apps/ezagent_core/lib/ezagent/workspace_owner_gate.ex \
  apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs
git commit -m "feat(core): add workspace owner gate"
```

### Task 3: Dispatch And Spawn Chokepoint Gates

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/invocation.ex`
- Modify: `apps/ezagent_core/lib/ezagent/spawn_registry.ex`
- Test: `apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs`

- [ ] **Step 1: Write failing dispatch and spawn invariant tests**

Create `apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs`:

```elixir
defmodule EzagentCore.Invariants.WorkspaceLocalityGateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, RuntimeIdentity, SpawnRegistry, WorkspacePlacement}

  defmodule RemoteResolver do
    @behaviour Ezagent.WorkspacePlacement
    def owner_of(%URI{scheme: "workspace"}), do: {:ok, "remote-node"}
  end

  setup do
    previous_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    previous_placement = Application.get_env(:ezagent_core, WorkspacePlacement)

    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "local-node")
    Application.put_env(:ezagent_core, WorkspacePlacement, resolver: RemoteResolver, mode: :enforce)

    on_exit(fn ->
      restore_env(RuntimeIdentity, previous_identity)
      restore_env(WorkspacePlacement, previous_placement)
    end)

    :ok
  end

  test "dispatch fails before local lookup or lazy spawn when workspace is owned remotely" do
    target = Ezagent.URI.new!("session://team-alpha/default/main?action=session.send")

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: Ezagent.URI.new!("entity://team-alpha/user/alice"), caps: MapSet.new(), reply: :ignore}
    }

    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert {:error,
            {:not_workspace_owner, ^workspace_uri, "remote-node", "local-node",
             {:dispatch, ^target}}} = Invocation.dispatch(inv)
  end

  test "spawn fails before local materialization when workspace is owned remotely" do
    uri =
      Ezagent.URI.new!(
        "session://team-alpha/default/locality-spawn-#{System.unique_integer([:positive])}"
      )

    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert {:error,
            {:not_workspace_owner, ^workspace_uri, "remote-node", "local-node",
             {:spawn, ^uri}}} = SpawnRegistry.spawn(uri)

    assert :error = Ezagent.KindRegistry.lookup(uri)
  end

  defp restore_env(_module, nil), do: Application.delete_env(:ezagent_core, _module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end
```

- [ ] **Step 2: Run invariant tests and verify RED**

Run:

```bash
mix test apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs
```

Expected: dispatch returns legacy `:no_such_actor` and spawn invokes the function, so tests fail.

- [ ] **Step 3: Gate dispatch before idempotency and lazy spawn**

Modify `Invocation.dispatch/1`:

```elixir
def dispatch(%__MODULE__{target: target, mode: mode, ctx: ctx} = inv) do
  instance_uri = Ezagent.URI.instance(target)

  with :ok <- Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(instance_uri, {:dispatch, target}),
       :ok <- maybe_idempotency_check(ctx) do
    dispatch_with_lazy_spawn(instance_uri, mode, inv)
  end
end
```

Keep unsupported mode handling unchanged.

- [ ] **Step 4: Gate spawn before KindRegistry lookup**

Modify `SpawnRegistry.spawn_detailed/1`:

```elixir
def spawn_detailed(%URI{scheme: scheme} = uri) when is_binary(scheme) do
  with :ok <- Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(uri, {:spawn, uri}) do
    do_spawn_detailed(uri, scheme)
  end
end

defp do_spawn_detailed(%URI{} = uri, scheme) do
  case Ezagent.KindRegistry.lookup(uri) do
    {:ok, pid} ->
      {:ok, :already_started, pid}

    :error ->
      case :ets.lookup(@table, scheme) do
        [{^scheme, fun}] ->
          case fun.(uri) do
            {:ok, pid} -> {:ok, :started, pid}
            {:error, {:already_started, pid}} -> {:ok, :already_started, pid}
            {:error, _} = err -> err
            other -> {:error, {:unexpected_spawn_fn_result, other}}
          end

        [] ->
          {:error, {:no_spawn_fn, scheme}}
      end
  end
end
```

- [ ] **Step 5: Run invariant tests and existing focused tests**

Run:

```bash
mix test apps/ezagent_core/test/ezagent/invocation_test.exs \
  apps/ezagent_core/test/ezagent/spawn_registry_test.exs \
  apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs
```

Expected: all pass.

- [ ] **Step 6: Commit PR 1 Task 3**

```bash
git add apps/ezagent_core/lib/ezagent/invocation.ex \
  apps/ezagent_core/lib/ezagent/spawn_registry.ex \
  apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs
git commit -m "feat(core): gate workspace dispatch and spawn"
```

### Task 4: Session Creator Gate

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex`
- Test: `apps/ezagent_domain_session/test/integration/session_creator_workspace_owner_gate_test.exs`

- [ ] **Step 1: Write failing session create gate test**

Create `apps/ezagent_domain_session/test/integration/session_creator_workspace_owner_gate_test.exs`:

```elixir
defmodule EzagentDomainInstanceMessage.Integration.SessionCreatorWorkspaceOwnerGateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{RuntimeIdentity, WorkspacePlacement}
  alias Ezagent.Entity.User
  alias EzagentDomainInstanceMessage.SessionCreator

  defmodule RemoteResolver do
    @behaviour Ezagent.WorkspacePlacement
    def owner_of(%URI{scheme: "workspace"}), do: {:ok, "remote-node"}
  end

  setup do
    previous_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    previous_placement = Application.get_env(:ezagent_core, WorkspacePlacement)

    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "local-node")
    Application.put_env(:ezagent_core, WorkspacePlacement, resolver: RemoteResolver, mode: :enforce)

    on_exit(fn ->
      restore_env(RuntimeIdentity, previous_identity)
      restore_env(WorkspacePlacement, previous_placement)
    end)

    :ok
  end

  test "create_session fails before materializing live session state when workspace is owned remotely" do
    short = "owner-gate-#{System.unique_integer([:positive])}"
    session_uri = Ezagent.URI.new!("session://system/default/#{short}")
    workspace_uri = Ezagent.URI.new!("workspace://system")

    assert {:error,
            {:not_workspace_owner, ^workspace_uri, "remote-node", "local-node",
             {:session_create, ^session_uri}}} =
             SessionCreator.create_session(short, User.admin_uri(), template_name: "default")

    assert :error = Ezagent.KindRegistry.lookup(session_uri)
  end

  defp restore_env(_module, nil), do: Application.delete_env(:ezagent_core, _module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end
```

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
mix test apps/ezagent_domain_session/test/integration/session_creator_workspace_owner_gate_test.exs
```

Expected: session creation currently proceeds farther than the owner gate, so the test fails.

- [ ] **Step 3: Gate create_session before node-local lock**

In `SessionCreator.create_session/3`, after `session_uri` is built and before `lock_id`, add:

```elixir
with :ok <-
       Ezagent.WorkspaceOwnerGate.assert_local_owner(
         workspace_uri,
         {:session_create, session_uri}
       ) do
  # existing lock_id/try block
end
```

Keep the existing short-name error clause unchanged.

- [ ] **Step 4: Gate repair_orchestrator before node-local lock**

In `repair_orchestrator/2`, after `_template_name = Ezagent.URI.type!(session_uri)` and before `lock_id`, add:

```elixir
with :ok <-
       Ezagent.WorkspaceOwnerGate.assert_local_owner(
         workspace_uri,
         {:session_repair, session_uri}
       ) do
  # existing lock_id/try block
end
```

- [ ] **Step 5: Run focused session tests**

Run:

```bash
mix test apps/ezagent_domain_session/test/integration/session_creator_workspace_owner_gate_test.exs \
  apps/ezagent_domain_session/test/integration/dynamic_session_test.exs \
  apps/ezagent_domain_session/test/integration/repair_orchestrator_test.exs
```

Expected: all pass.

- [ ] **Step 6: Commit PR 1 Task 4**

```bash
git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex \
  apps/ezagent_domain_session/test/integration/session_creator_workspace_owner_gate_test.exs
git commit -m "feat(session): gate session creation by workspace owner"
```

### Task 5: PR 1 Validation

**Files:**
- No code files.

- [ ] **Step 1: Run PR 1 focused suite**

Run:

```bash
mix test apps/ezagent_core/test/ezagent/workspace_owner_gate_test.exs \
  apps/ezagent_core/test/ezagent/invocation_test.exs \
  apps/ezagent_core/test/ezagent/spawn_registry_test.exs \
  apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs \
  apps/ezagent_domain_session/test/integration/session_creator_workspace_owner_gate_test.exs \
  apps/ezagent_domain_session/test/integration/dynamic_session_test.exs \
  apps/ezagent_domain_session/test/integration/repair_orchestrator_test.exs
```

Expected: all pass.

- [ ] **Step 2: Run precommit from the PR 1 branch**

Run:

```bash
mix precommit
```

Expected: pass, or document baseline/environment failures with exact failing app/test.

## PR 2: Plugin Contract And Invariants

### Task 6: Plugin Contract Documentation

**Files:**
- Create: `docs/superpowers/specs/2026-06-24-workspace-locality-plugin-contract.md`

- [ ] **Step 1: Add plugin contract doc**

Create the doc with these sections:

```markdown
# Workspace Locality Plugin Contract

Plugin workspace-bound side effects must enter core through owner-gated APIs.

Forbidden in plugin apps:

- direct `Ezagent.KindRegistry.lookup/1` decisions for workspace-bound actors;
- direct `Registry.lookup(Ezagent.KindRegistry, ...)`;
- direct `GenServer.call/cast` to workspace-bound Kind pids;
- direct `Ezagent.SpawnRegistry.spawn/1` or `spawn_detailed/1` except through an approved owner-gated core wrapper;
- external ingress fallback to a local default workspace.

Allowed without owner gate:

- plugin boot metadata registration;
- behavior/capability metadata reads;
- health checks and metrics;
- read-only static manifest/template catalog reads.

Every exception must be centralized in the architecture invariant allowlist with a one-line reason.
```

- [ ] **Step 2: Commit plugin contract doc**

```bash
git add docs/superpowers/specs/2026-06-24-workspace-locality-plugin-contract.md
git commit -m "docs: add workspace locality plugin contract"
```

### Task 7: Plugin Architecture Invariant

**Files:**
- Create: `apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs`

- [ ] **Step 1: Write failing architecture scan**

Create a test that scans `apps/ezagent_plugin_*/lib/**/*.ex` plus plugin-owned external ingress files for direct local registry/spawn patterns, with a centralized allowlist:

```elixir
defmodule EzagentCore.Invariants.PluginWorkspaceLocalityContractTest do
  use ExUnit.Case, async: true

  @forbidden_patterns [
    {~r/Ezagent\.KindRegistry\.lookup\s*\(/, "Use owner-gated core APIs instead of direct KindRegistry lookup."},
    {~r/Registry\.lookup\s*\(\s*Ezagent\.KindRegistry\s*,/, "Use owner-gated core APIs instead of direct Registry lookup."},
    {~r/Ezagent\.SpawnRegistry\.spawn(?:_detailed)?\s*\(/, "Use an owner-gated core wrapper instead of direct SpawnRegistry calls."}
  ]

  @allowlist %{
    "apps/ezagent_core/lib/ezagent/spawn_registry.ex" =>
      "core chokepoint that owns the owner gate"
  }

  test "plugin apps do not bypass workspace owner gate through local registry or spawn APIs" do
    apps_root = Path.expand("../../../..", __DIR__)

    violations =
      apps_root
      |> production_plugin_files()
      |> Enum.flat_map(&violations_in_file(apps_root, &1))

    assert violations == [],
           """
           Plugin workspace locality contract violations:

           #{Enum.map_join(violations, "\n", fn {path, message} -> "  #{path}: #{message}" end)}

           Workspace-bound plugin side effects must enter owner-gated core APIs.
           Add a centralized allowlist entry only for system-global metadata or already-gated code.
           """
  end

  defp production_plugin_files(apps_root) do
    apps_root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "ezagent_plugin_"))
    |> Enum.flat_map(fn app ->
      lib_dir = Path.join([apps_root, "apps", app, "lib"])
      if File.dir?(lib_dir), do: list_ex_files(lib_dir), else: []
    end)
  end

  defp violations_in_file(apps_root, full_path) do
    rel_path = Path.relative_to(full_path, apps_root)

    if Map.has_key?(@allowlist, rel_path) do
      []
    else
      content = File.read!(full_path)

      Enum.flat_map(@forbidden_patterns, fn {pattern, message} ->
        if Regex.match?(pattern, content), do: [{rel_path, message}], else: []
      end)
    end
  end

  defp list_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> list_ex_files(full)
        String.ends_with?(entry, ".ex") -> [full]
        true -> []
      end
    end)
  end
end
```

- [ ] **Step 2: Run invariant and capture current violations**

Run:

```bash
mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Expected: fail if plugins currently call local registry/spawn directly.

- [ ] **Step 3: Triage violations**

For each violation:

- If it is system-global metadata or already owner-gated, add it to `@allowlist` with a one-line reason.
- If it is workspace-bound and not owner-gated, route the path through an existing owner-gated core API or create a minimal wrapper in core.
- Re-run the invariant after every triage change.

- [ ] **Step 4: Verify invariant passes**

Run:

```bash
mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Expected: pass with reasoned allowlist.

- [ ] **Step 5: Commit plugin invariant**

```bash
git add apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs \
  docs/superpowers/specs/2026-06-24-workspace-locality-plugin-contract.md
git commit -m "test(core): guard plugin workspace locality contract"
```

### Task 8: PR 2 Validation And Final Return Prep

**Files:**
- Create: `docs/together/2026-06-24/returns/remove-localization-assumption.md`

- [ ] **Step 1: Run PR 2 focused suite**

Run:

```bash
mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs \
  apps/ezagent_core/test/invariants/workspace_locality_gate_test.exs
```

Expected: all pass.

- [ ] **Step 2: Run precommit**

Run:

```bash
mix precommit
```

Expected: pass, or document baseline/environment failures with exact failing app/test.

- [ ] **Step 3: Prepare dev-together return after both PR branches merge into `remove-localization-assumption`**

Create `docs/together/2026-06-24/returns/remove-localization-assumption.md` with:

```markdown
> **Task:** remove-localization-assumption
> **Branch:** `remove-localization-assumption`
> **PRs:** PR 1 core gate, PR 2 plugin invariants
> **Dev:** Codex
> **returned_at:** 2026-06-24 HH:MM +0800
> **deadline:** none
> **deadline_status:** out_of_scope

# Return: remove-localization-assumption

## Summary

Implemented behavior-preserving workspace locality gates and plugin bypass invariants.

## What Changed

- Runtime identity and workspace placement facade.
- Workspace owner gate in dispatch, spawn, and session create/repair.
- Plugin workspace locality contract and architecture invariant.

## Validation

- Focused tests: record the exact focused commands from Step 1 and whether they passed.
- `mix precommit`: record the exact command result from Step 2.

## Exposed Local Assumptions

- Record each existing local assumption surfaced by observe/invariant work, or write `None surfaced by this slice`.

## Remaining Risks

- Record deferred ingress paths and any baseline/environment failures, or write `None known after validation`.
```

- [ ] **Step 4: Commit return**

```bash
git add docs/together/2026-06-24/returns/remove-localization-assumption.md
git commit -m "dev-together(return): remove-localization-assumption"
```

## Self-Review

- Spec coverage: PR 1 covers runtime identity, placement, owner gate, dispatch, spawn, and session create/repair. PR 2 covers plugin contract, architecture invariants, and dev-together return.
- Placeholder scan: plan has no `TBD`, `TODO`, or vague "implement later" steps. The final return section uses explicit instructions for values that must be filled after validation.
- Type consistency: all planned APIs use `URI.t()` workspace URIs and structured operation tuples matching the approved design.
