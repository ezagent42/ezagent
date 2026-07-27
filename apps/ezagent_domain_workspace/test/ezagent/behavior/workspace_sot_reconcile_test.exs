defmodule Ezagent.ActionSet.WorkspaceSotReconcileTest do
  @moduledoc """
  SoT-load + cold-restart invariant gate for the
  `Ezagent.ActionSet.Workspace` Lifecycle migration (Phase B, SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6) — the
  EXTERNAL-SoT, NO-TRANSIENTS shape.

  The Workspace Kind is `persistence :ephemeral` (`Ezagent.Entity.Workspace`):
  the `kind_snapshots` BLOB is NEVER its source of truth. The `workspaces`
  SQLite table (`Ezagent.Workspace.Store`) is the SoT; `Ezagent.Workspace.Loader`
  decodes the row and threads it into the spawn args, so the SoT load lives
  in `create/1`-from-args (NOT a separate `activate` reconcile — see the
  Behavior moduledoc for the deliberate OQ-8 deviation rationale: a separate
  reconcile is both redundant here AND would clobber live runtime mutations).

  The architectural invariant for this NO-TRANSIENTS, create-from-args
  module is therefore:

    1. `create/1` builds the cluster-shape `state` from the SoT-derived
       spawn args on EVERY start.
    2. State MUST survive a brutal cold restart — an OTP crash-restart of
       the `:permanent` Kind re-threads the SAME `{kind_module, params}`
       spawn args via the child spec, so `create/1` rebuilds the identical
       SoT-derived state. No state is lost; no transient is carried (a
       Workspace holds none).

  Per `feedback_completion_requires_invariant_test`: this FAILS exactly
  when the cold-restart rehydrate breaks (state lost across a crash because
  the SoT-from-args load was dropped from `create/1`).
  """

  use Ezagent.LifecycleCase

  alias Ezagent.ActionSet.Workspace, as: WB

  # Workspace-Behavior-only test Kind. `:ephemeral` mirrors the production
  # `Ezagent.Entity.Workspace`. `uri_from_args/1` lets `Ezagent.Kind.spawn/2`
  # build the child spec from `args[:uri]` — the SAME args (incl. members /
  # templates / rules) are re-threaded on an OTP crash-restart, which is
  # exactly what rehydrates the state. No `supervisor/0` → `:permanent`
  # child of the core `Ezagent.KindSupervisor`, so `Process.exit(pid, :kill)`
  # triggers an OTP auto-restart at the same URI.
  defmodule WorkspaceOnlyKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    # DISTINCT type_name (NOT the production `:workspace`). The Kind is
    # registered into the GLOBAL BehaviorRegistry on spawn; reusing
    # `:workspace` made this throwaway stub (which carries only the
    # Workspace Behavior's read actions) collide with the real
    # `Ezagent.Entity.Workspace` in `EzagentCli.TreeBuilder`'s
    # type-name-keyed CLI-tree derivation under cross-app concurrency,
    # shadowing the real `workspace` subcommand and dropping `add_member`
    # / `instantiate` (CLIDispatchTest failures). The slice name
    # (`:workspace`, from WB.state_slice) and the `workspace://` URI are
    # independent of this Kind's `type_name`, so a distinct value changes
    # nothing about what this test exercises.
    @impl Ezagent.Kind
    def type_name, do: :workspace_sot_stub

    @impl Ezagent.Kind
    def behaviors, do: [WB]

    @impl Ezagent.Kind
    def persistence, do: :ephemeral

    @impl Ezagent.Kind
    def uri_from_args(args), do: Map.fetch!(args, :uri)
  end

  setup_all do
    Code.ensure_loaded!(WB)
    Code.ensure_loaded!(WorkspaceOnlyKind)

    for action <- [:list_members, :list_templates, :list_routing_rules] do
      if Ezagent.BehaviorRegistry.lookup(WorkspaceOnlyKind, action) == :error do
        :ok = Ezagent.CapabilityRegistry.register(WorkspaceOnlyKind, action, WB)
      end
    end

    :ok
  end

  test "no-transients: SoT-from-args state survives cold restart; create rebuilds it" do
    name = "ws-cold-restart-#{System.unique_integer([:positive])}"
    workspace_uri = URI.new!("workspace://#{name}")

    member = URI.new!("entity://#{name}/user/alice")
    tmpl = %{"class" => "py.agent", "agent_uri" => "entity://#{name}/agent/py_x"}
    rule = %{"matcher" => %{"type" => "always"}, "receivers" => ["session://x/default/x"]}

    # Loader-equivalent spawn: the decoded SoT cluster shape threaded as
    # args. (The production Loader reads the `workspaces` row and passes
    # exactly these.)
    spawn_args = %{
      uri: workspace_uri,
      members: [member],
      session_templates: %{"echo.demo" => tmpl},
      routing_rules: [rule]
    }

    # 1. Spawn fresh — create/1 builds the cluster-shape state from args.
    {:ok, pid1} = Ezagent.Kind.spawn(WorkspaceOnlyKind, spawn_args)
    wait_until(fn -> Ezagent.ReadyGate.status(workspace_uri) == :ready end)

    {:ok, %{state: state_before, transients: tr_before}} =
      Ezagent.Kind.SliceAccess.get_raw_slice(workspace_uri, :workspace)

    assert MapSet.member?(state_before.members, member)
    assert state_before.session_templates == %{"echo.demo" => tmpl}
    assert state_before.routing_rules == [rule]
    assert tr_before == %{}, "Workspace holds NO transient"

    # 2. Brutal kill — skips graceful deactivate/terminate. The :permanent
    #    child is OTP-auto-restarted at the same URI WITH THE SAME spawn
    #    args (re-threaded via the child spec), so create/1 rebuilds the
    #    SoT-derived state.
    Process.exit(pid1, :kill)

    wait_until(fn ->
      case Ezagent.KindRegistry.lookup(workspace_uri) do
        {:ok, p} when p != pid1 -> Ezagent.ReadyGate.status(workspace_uri) == :ready
        _ -> false
      end
    end)

    {:ok, pid2} = Ezagent.KindRegistry.lookup(workspace_uri)
    refute pid1 == pid2, "cold restart must produce a new pid"

    # 3. THE GATE — state rehydrated identically (create-from-args ran with
    #    the re-threaded SoT args); still no transient.
    {:ok, %{state: state_after, transients: tr_after}} =
      Ezagent.Kind.SliceAccess.get_raw_slice(workspace_uri, :workspace)

    assert state_after == state_before,
           "cluster-shape state did NOT survive the cold restart — the " <>
             "SoT-from-args load must rebuild it in create/1 on every start"

    assert tr_after == %{}

    on_exit(fn ->
      case Ezagent.KindRegistry.lookup(workspace_uri) do
        {:ok, _p} -> Ezagent.Kind.terminate(workspace_uri)
        _ -> :ok
      end
    end)
  end

  test "create/1 loads the cluster shape from the (Loader-threaded) SoT args" do
    name = "ws-create-#{System.unique_integer([:positive])}"
    member = URI.new!("entity://#{name}/user/seed")
    tmpl = %{"class" => "py.agent"}

    assert {:ok, state} =
             WB.create(%{
               members: [member],
               session_templates: %{"t" => tmpl},
               routing_rules: [%{"r" => 1}]
             })

    assert MapSet.member?(state.members, member)
    assert state.session_templates == %{"t" => tmpl}
    assert state.routing_rules == [%{"r" => 1}]
  end
end
